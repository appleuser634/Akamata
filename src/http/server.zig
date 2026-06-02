const std = @import("std");
const parser = @import("parser.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const status = @import("status.zig");
const ctx_mod = @import("../legacy_ctx.zig");
const router_mod = @import("../router.zig");
const middleware_mod = @import("../middleware.zig");

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
        };

        gpa: std.mem.Allocator,
        io: Io,
        app: *App,
        opts: Opts,
        listener: ?net.Server = null,
        shutdown_flag: std.atomic.Value(bool) = .init(false),

        pub fn init(gpa: std.mem.Allocator, io: Io, app: *App, opts: Opts) !Self {
            return .{ .gpa = gpa, .io = io, .app = app, .opts = opts };
        }

        pub fn deinit(self: *Self) void {
            if (self.listener) |*l| l.deinit(self.io);
            self.listener = null;
        }

        pub fn requestShutdown(self: *Self) void {
            self.shutdown_flag.store(true, .seq_cst);
            // Closing the listener socket causes accept() to return SocketNotListening.
            if (self.listener) |*l| l.socket.close(self.io);
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
            defer if (self.listener) |*l| {
                l.deinit(self.io);
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
                handleConnection(self, stream) catch |err| {
                    if (self.opts.on_uncaught) |cb| cb(err) else std.log.err("conn error: {t}", .{err});
                };
            }
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

            const recv_buf = try self.gpa.alloc(u8, self.opts.read_buffer_bytes);
            defer self.gpa.free(recv_buf);

            // Use Stream.Reader with our own buffer. We drain it into a contiguous
            // request buffer via `readVec`, which issues a single read syscall and
            // returns whatever the kernel had available — unlike `readSliceShort`
            // which loops to fill the entire destination buffer.
            var sock_reader_buf: [4096]u8 = undefined;
            var sr = stream.reader(self.io, &sock_reader_buf);
            const r: *Io.Reader = &sr.interface;

            var pending_len: usize = 0;
            keep_alive: while (true) {
                _ = arena_state.reset(.retain_capacity);
                const arena = arena_state.allocator();

                // Read until we have a complete header block.
                while (parser.headersEnd(recv_buf[0..pending_len]) == null) {
                    if (pending_len == recv_buf.len) return error.HeadersTooLarge;
                    var vec: [1][]u8 = .{recv_buf[pending_len..]};
                    const n = r.readVec(&vec) catch return;
                    if (n == 0) return;
                    pending_len += n;
                }

                // Parse headers + body (read more if body is short)
                const parsed = blk: while (true) {
                    const p = parser.parseRequest(arena, recv_buf[0..pending_len], self.opts.parse_limits) catch |e| switch (e) {
                        parser.ParseError.Incomplete => {
                            if (pending_len == recv_buf.len) return error.PayloadTooLarge;
                            var vec: [1][]u8 = .{recv_buf[pending_len..]};
                            const n = r.readVec(&vec) catch return;
                            if (n == 0) return;
                            pending_len += n;
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

                const total = parsed.consumed;
                if (total < pending_len) {
                    std.mem.copyForwards(u8, recv_buf[0 .. pending_len - total], recv_buf[total..pending_len]);
                    pending_len -= total;
                } else {
                    pending_len = 0;
                }
                continue :keep_alive;
            }
        }
    };
}
