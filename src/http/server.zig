const std = @import("std");
const parser = @import("parser.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const status = @import("status.zig");
const ctx_mod = @import("../legacy_ctx.zig");
const router_mod = @import("../router.zig");
const middleware_mod = @import("../middleware.zig");
const clock = @import("../observability/clock.zig");

const Io = std.Io;
const net = std.Io.net;

pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();
        pub const Mw = middleware_mod.Middleware(App);
        pub const Opts = struct {
            address: net.IpAddress,
            router: router_mod.Router(App),
            middlewares: []const Mw = &.{},
            on_uncaught: ?*const fn (err: anyerror) void = null,
            parse_limits: parser.Limits = .{},
            read_buffer_bytes: usize = 16 * 1024,
            write_buffer_bytes: usize = 16 * 1024,
            accept_thread_count: usize = 4,
            header_read_timeout_ms: u32 = 10_000,
            body_read_timeout_ms: u32 = 30_000,
            keep_alive_idle_timeout_ms: u32 = 5_000,
            total_request_timeout_ms: u32 = 60_000,
            max_requests_per_connection: u32 = 100,
            max_connections: usize = 1024,
        };

        gpa: std.mem.Allocator,
        io: Io,
        app: *App,
        opts: Opts,
        listener: ?net.Server = null,
        listener_closed: std.atomic.Value(bool) = .init(false),
        shutdown_flag: std.atomic.Value(bool) = .init(false),
        active_connections: std.atomic.Value(usize) = .init(0),

        pub fn init(gpa: std.mem.Allocator, io: Io, app: *App, opts: Opts) !Self {
            return .{ .gpa = gpa, .io = io, .app = app, .opts = opts };
        }

        pub fn deinit(self: *Self) void {
            if (self.listener) |*l| {
                if (!self.listener_closed.swap(true, .acq_rel)) l.deinit(self.io);
            }
            self.listener = null;
        }

        pub fn requestShutdown(self: *Self) void {
            self.shutdown_flag.store(true, .seq_cst);
            // Closing a listening descriptor from another thread does not
            // reliably interrupt a blocking accept(2) on Linux. Connect a
            // short-lived local stream instead; the accept loop wakes, owns
            // that stream normally, then observes shutdown_flag. The server
            // thread remains the sole owner responsible for closing listener.
            if (self.listener != null) {
                var address = self.opts.address;
                if (net.IpAddress.connect(&address, self.io, .{ .mode = .stream })) |wake| {
                    wake.close(self.io);
                } else |_| {}
            }
        }

        pub fn boundPort(self: *Self) ?u16 {
            if (self.listener) |*l| {
                // Best-effort: read back socket name via getsockname not yet exposed in 0.16.
                _ = l;
            }
            return null;
        }

        pub fn run(self: *Self) !void {
            self.listener = try net.IpAddress.listen(&self.opts.address, self.io, .{
                .reuse_address = true,
            });
            self.listener_closed.store(false, .release);
            defer if (self.listener) |*l| {
                if (!self.listener_closed.swap(true, .acq_rel)) l.deinit(self.io);
                self.listener = null;
            };
            std.log.info("akamata listening", .{});

            const n_threads = @max(self.opts.accept_thread_count, 1);
            var threads: std.ArrayList(std.Thread) = .empty;
            defer threads.deinit(self.gpa);
            try threads.ensureTotalCapacity(self.gpa, n_threads);

            var i: usize = 1;
            while (i < n_threads) : (i += 1) {
                const t = try std.Thread.spawn(.{}, acceptLoop, .{self});
                threads.appendAssumeCapacity(t);
            }
            acceptLoop(self);
            for (threads.items) |t| t.join();
            while (self.active_connections.load(.acquire) != 0) std.Thread.yield() catch {};
        }

        fn acceptLoop(self: *Self) void {
            while (!self.shutdown_flag.load(.seq_cst)) {
                if (self.listener == null) return;
                const stream = self.listener.?.accept(self.io) catch |err| {
                    if (self.shutdown_flag.load(.seq_cst)) return;
                    if (err == error.SocketNotListening) return;
                    std.log.warn("accept failed: {t}", .{err});
                    continue;
                };
                const active = self.active_connections.fetchAdd(1, .acq_rel);
                if (active >= self.opts.max_connections) {
                    _ = self.active_connections.fetchSub(1, .acq_rel);
                    stream.close(self.io);
                    continue;
                }
                const thread = std.Thread.spawn(.{}, connectionThread, .{ self, stream }) catch {
                    _ = self.active_connections.fetchSub(1, .acq_rel);
                    stream.close(self.io);
                    continue;
                };
                thread.detach();
            }
        }

        fn connectionThread(self: *Self, stream: net.Stream) void {
            defer _ = self.active_connections.fetchSub(1, .acq_rel);
            handleConnection(self, stream) catch |err| {
                if (err == error.Timeout or err == error.EndOfStream) return;
                if (self.opts.on_uncaught) |cb| cb(err) else std.log.warn("conn rejected: {t}", .{err});
            };
        }

        fn handleConnection(self: *Self, stream: net.Stream) !void {
            // Track ownership: a successful WS upgrade transfers the socket to
            // the ws.Conn, which becomes responsible for closing it. Closing
            // here too would double-close the fd and may end up closing an
            // unrelated socket that the kernel has since reassigned to the
            // same fd number (leading to BADF panics on other threads).
            var owns_stream = true;
            defer if (owns_stream) stream.close(self.io);
            var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena_state.deinit();

            var recv_buf: std.ArrayList(u8) = .empty;
            defer recv_buf.deinit(self.gpa);
            try recv_buf.ensureTotalCapacity(self.gpa, @max(@min(self.opts.read_buffer_bytes, self.opts.parse_limits.max_request_bytes + 4), 1));

            // Use Stream.Reader with our own buffer. We drain it into a contiguous
            // request buffer via `readVec`, which issues a single read syscall and
            // returns whatever the kernel had available — unlike `readSliceShort`
            // which loops to fill the entire destination buffer.
            var sock_reader_buf: [4096]u8 = undefined;
            var sr = stream.reader(self.io, &sock_reader_buf);
            const r: *Io.Reader = &sr.interface;

            var pending_len: usize = 0;
            var request_count: u32 = 0;
            keep_alive: while (true) {
                _ = arena_state.reset(.retain_capacity);
                const arena = arena_state.allocator();

                const request_start = clock.monotonicNs();
                var first_read = pending_len == 0;
                // Read until we have a complete header block.
                while (parser.headersEnd(recv_buf.items[0..pending_len]) == null) {
                    if (pending_len >= self.opts.parse_limits.max_request_bytes + 4) return error.HeadersTooLarge;
                    try growReadBuffer(&recv_buf, self.gpa, pending_len, self.opts.parse_limits.max_request_bytes + 4);
                    var vec: [1][]u8 = .{recv_buf.allocatedSlice()[pending_len..recv_buf.capacity]};
                    const phase_ms = if (first_read and request_count > 0) self.opts.keep_alive_idle_timeout_ms else self.opts.header_read_timeout_ms;
                    const n = try timedRead(r, stream.socket.handle, &vec, boundedTimeout(phase_ms, self.opts.total_request_timeout_ms, request_start));
                    first_read = false;
                    pending_len += n;
                    recv_buf.items.len = pending_len;
                }

                // Parse headers + body (read more if body is short)
                const parsed = blk: while (true) {
                    const p = parser.parseRequest(arena, recv_buf.items[0..pending_len], self.opts.parse_limits) catch |e| switch (e) {
                        parser.ParseError.Incomplete => {
                            const maximum = std.math.add(usize, self.opts.parse_limits.max_request_bytes + 4, self.opts.parse_limits.max_body_bytes) catch return error.PayloadTooLarge;
                            if (pending_len >= maximum) return error.PayloadTooLarge;
                            try growReadBuffer(&recv_buf, self.gpa, pending_len, maximum);
                            var vec: [1][]u8 = .{recv_buf.allocatedSlice()[pending_len..recv_buf.capacity]};
                            const n = try timedRead(r, stream.socket.handle, &vec, boundedTimeout(self.opts.body_read_timeout_ms, self.opts.total_request_timeout_ms, request_start));
                            pending_len += n;
                            recv_buf.items.len = pending_len;
                            continue;
                        },
                        else => return e,
                    };
                    break :blk p;
                };

                var req = parsed.request;
                var res: response.Response = .init(arena);
                res.keep_alive = req.keep_alive;

                // Pre-create the socket writer so streaming handlers can
                // attach to it via `res.startStream()`.
                var sock_writer_buf: [4096]u8 = undefined;
                var sw = stream.writer(self.io, &sock_writer_buf);
                const w: *Io.Writer = &sw.interface;
                res.socket_writer = w;

                var name_buf: [16][]const u8 = undefined;
                var value_buf: [16][]const u8 = undefined;

                const match = self.opts.router.match(req.method, req.path, &name_buf, &value_buf);

                var ctx: ctx_mod.Ctx(App) = .{
                    .app = self.app,
                    .req = &req,
                    .res = &res,
                    .arena = arena,
                    .params = if (match) |m| m.params else .{},
                    .stream_ptr = @ptrCast(@constCast(&stream)),
                    .io_ptr = @ptrCast(@constCast(&self.io)),
                };

                if (match) |m| {
                    const Term = struct {
                        var handler: router_mod.Handler(App) = undefined;
                        fn call(c: *ctx_mod.Ctx(App)) anyerror!void {
                            return handler(c);
                        }
                    };
                    Term.handler = m.handler;
                    middleware_mod.run(App, self.opts.middlewares, Term.call, &ctx) catch |err| {
                        if (self.opts.on_uncaught) |cb| cb(err);
                        // A streaming response can't recover here: headers
                        // are gone and partial chunks may already be on the
                        // wire. Just terminate the response.
                        if (res.streaming) |cw| {
                            cw.end() catch {};
                        } else if (res.body.items.len == 0 and res.status_code == 200) {
                            res.setStatus(500);
                            res.json(.{ .error_kind = "internal", .message = "internal server error" }) catch {};
                        }
                    };
                } else {
                    res.setStatus(404);
                    try res.json(.{ .error_kind = "not_found", .path = req.path });
                }

                // For protocol upgrades (e.g. WebSocket), the handler has
                // already written the 101 response and now owns the socket.
                // Writing again here would race with the ws.Conn lifecycle.
                if (res.is_upgrade) {
                    owns_stream = false; // handler (ws.Conn) now owns the socket
                    return;
                }

                // Streaming response: finalize the zero-chunk + flush. Then
                // close the connection (we already set keep_alive=false).
                if (res.streaming) |cw| {
                    cw.end() catch return;
                    w.flush() catch return;
                    return;
                }

                // Buffered response: build into arena, write all at once.
                var alloc_w: Io.Writer.Allocating = .init(arena);
                try res.writeTo(&alloc_w.writer);
                const out = alloc_w.writer.buffered();
                w.writeAll(out) catch return;
                w.flush() catch return;

                if (!res.keep_alive) return;
                request_count += 1;
                if (request_count >= self.opts.max_requests_per_connection) return;

                const total = parsed.consumed;
                if (total < pending_len) {
                    std.mem.copyForwards(u8, recv_buf.items[0 .. pending_len - total], recv_buf.items[total..pending_len]);
                    pending_len -= total;
                    recv_buf.items.len = pending_len;
                } else {
                    pending_len = 0;
                    recv_buf.items.len = 0;
                }
                continue :keep_alive;
            }
        }
    };
}

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 = 0 };
const POLLIN: i16 = 0x0001;
extern "c" fn poll(fds: [*]PollFd, nfds: c_uint, timeout_ms: c_int) c_int;

fn growReadBuffer(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, used: usize, maximum: usize) !void {
    if (buf.capacity > used) return;
    const next = @min(maximum, @max(used +| 1, buf.capacity *| 2));
    if (next <= used) return error.PayloadTooLarge;
    try buf.ensureTotalCapacity(allocator, next);
}

fn boundedTimeout(phase_ms: u32, total_ms: u32, started_ns: u64) u32 {
    const elapsed_ms = clock.elapsedNs(started_ns) / std.time.ns_per_ms;
    if (elapsed_ms >= total_ms or elapsed_ms >= phase_ms) return 0;
    return @min(@as(u32, @intCast(phase_ms - elapsed_ms)), @as(u32, @intCast(total_ms - elapsed_ms)));
}

fn timedRead(r: *Io.Reader, fd: c_int, vec: [][]u8, timeout_ms: u32) !usize {
    var pfd = [_]PollFd{.{ .fd = fd, .events = POLLIN }};
    if (timeout_ms == 0 or poll(&pfd, 1, @intCast(@min(timeout_ms, std.math.maxInt(c_int)))) <= 0 or (pfd[0].revents & POLLIN) == 0) return error.Timeout;
    const n = r.readVec(vec) catch return error.EndOfStream;
    if (n == 0) return error.EndOfStream;
    return n;
}
