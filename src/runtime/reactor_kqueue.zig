// kqueue thread-per-core reactor (PERF7).
//
// Architecture:
//
//   ┌──────────────────────────────────────────────────┐
//   │ Accept thread                                    │
//   │   blocking accept(2)                             │
//   │   pick worker by round-robin                     │
//   │   write(pipe[w], &fd, sizeof fd)                 │
//   └────────────────┬─────────────────────────────────┘
//                    │ one byte-sized message per fd
//                    ▼
//   ┌──────────────────────────────────────────────────┐
//   │ Worker thread × N (= cpu_count)                  │
//   │   own kqueue                                     │
//   │   own conns: AutoHashMap(fd, *Conn)              │
//   │   kqueue watches: pipe[w][0] + each owned fd     │
//   │   on pipe readable → drain new fds + register    │
//   │   on conn readable → read + dispatch + write     │
//   └──────────────────────────────────────────────────┘
//
// Why this is faster than the previous {1 reactor + worker pool}:
//
//   * No MPMC queue mutex on the hot path. Every kqueue/handler/socket
//     call stays on the same thread, so the connection's cache lines
//     never bounce between cores.
//   * No EV_ONESHOT re-arm cross-thread call. The worker's own kqueue
//     re-arms locally — kqueue has no FD-affinity requirement, but in
//     this design every fd is touched only by one thread anyway.
//   * Single-threaded code paths inside a worker are exactly the same
//     shape as the old "threaded" runtime, except multiplexed over many
//     fds via kqueue instead of one fd per thread.
//
// Out of scope for this iteration:
//
//   * Backpressure-aware accept (we just drop on accept errors)
//   * Graceful shutdown (workers exit when shutdown_flag is set)
//   * Multi-accept (using SO_REUSEPORT to give each worker its own
//     listening fd — would save the pipe hop, but means accept(2) calls
//     happen on every worker which doesn't actually help on macOS)
//
// Build: this file is selected by `src/serve.zig` when
//   - `opts.runtime == .reactor`
//   - and the target OS is BSD-family.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const req_mod = @import("../http/request.zig");
const res_mod = @import("../http/response.zig");
const parser = @import("../http/parser.zig");

// ---------------------- libc bindings (BSD/Darwin) -----------------------

const c_int_t = c_int;
const c_long_t = c_long;

const SOCK_STREAM: c_int_t = 1;
const AF_INET: c_int_t = 2;
const IPPROTO_TCP: c_int_t = 6;
const SOL_SOCKET: c_int_t = 0xffff;
const SO_REUSEADDR: c_int_t = 0x0004;
const SO_REUSEPORT: c_int_t = 0x0200;
const TCP_NODELAY: c_int_t = 1;
const F_GETFL: c_int_t = 3;
const F_SETFL: c_int_t = 4;
const O_NONBLOCK: c_int_t = 0x0004;

const EVFILT_READ: i16 = -1;
const EV_ADD: u16 = 0x0001;
const EV_DELETE: u16 = 0x0002;
const EV_ENABLE: u16 = 0x0004;
const EV_DISABLE: u16 = 0x0008;
const EV_ONESHOT: u16 = 0x0010;
const EV_CLEAR: u16 = 0x0020;
const EV_EOF: u16 = 0x8000;
const EV_ERROR: u16 = 0x4000;

const SockAddrIn = extern struct {
    sin_len: u8 = @sizeOf(SockAddrIn),
    sin_family: u8 = AF_INET,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

const Kevent = extern struct {
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: isize,
    udata: usize,
};

const Timespec = extern struct {
    tv_sec: c_long_t,
    tv_nsec: c_long_t,
};

extern "c" fn socket(domain: c_int_t, sock_type: c_int_t, protocol: c_int_t) c_int_t;
extern "c" fn setsockopt(fd: c_int_t, level: c_int_t, optname: c_int_t, optval: *const anyopaque, optlen: u32) c_int_t;
extern "c" fn bind(fd: c_int_t, addr: *const SockAddrIn, len: u32) c_int_t;
extern "c" fn listen(fd: c_int_t, backlog: c_int_t) c_int_t;
extern "c" fn accept(fd: c_int_t, addr: ?*anyopaque, addrlen: ?*u32) c_int_t;
extern "c" fn close(fd: c_int_t) c_int_t;
extern "c" fn read(fd: c_int_t, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int_t, buf: [*]const u8, count: usize) isize;
extern "c" fn fcntl(fd: c_int_t, cmd: c_int_t, ...) c_int_t;
extern "c" fn pipe(fds: [*]c_int_t) c_int_t;
extern "c" fn kqueue() c_int_t;
extern "c" fn kevent(
    kq: c_int_t,
    changelist: ?[*]const Kevent,
    nchanges: c_int_t,
    eventlist: ?[*]Kevent,
    nevents: c_int_t,
    timeout: ?*const Timespec,
) c_int_t;
extern "c" fn __error() *c_int_t;

inline fn errnoVal() c_int_t {
    return __error().*;
}

inline fn htons(x: u16) u16 {
    return std.mem.nativeToBig(u16, x);
}

inline fn parseIpv4(s: []const u8) !u32 {
    var parts: [4]u8 = undefined;
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (idx >= 4) return error.InvalidAddress;
        parts[idx] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
        idx += 1;
    }
    if (idx != 4) return error.InvalidAddress;
    const be: u32 = (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) |
        (@as(u32, parts[2]) << 8) | @as(u32, parts[3]);
    return std.mem.nativeToBig(u32, be);
}

inline fn isEagain(e: c_int_t) bool {
    return e == 35 or e == 11; // EAGAIN
}

// ---------------------- Per-connection state -----------------------------

const recv_cap = 16 * 1024;
/// Stack-allocated output buffer per worker. 16 KB covers the vast majority
/// of REST responses (JSON, HTML pages up to ~10 KB after headers). Larger
/// responses fall back to an arena allocation in `processOne`.
const send_cap = 16 * 1024;

const Conn = struct {
    fd: c_int_t,
    recv_buf: [recv_cap]u8 = undefined,
    pending: usize = 0,
    arena_state: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator, fd: c_int_t) !*Conn {
        const c = try gpa.create(Conn);
        c.* = .{
            .fd = fd,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
        };
        return c;
    }

    fn deinit(self: *Conn, gpa: std.mem.Allocator) void {
        self.arena_state.deinit();
        _ = close(self.fd);
        gpa.destroy(self);
    }
};

// ---------------------- Worker context -----------------------------------
//
// One per worker thread. Owns:
//   * its kqueue fd
//   * its read end of the accept→worker pipe
//   * its conns map
//   * the send_buf — reused across requests on the same worker
//
// Workers share nothing with each other. The accept thread is the only one
// that ever calls `write(pipe_write, ...)`, so the pipe itself is
// single-writer / single-reader.

fn WorkerCtx(comptime State: type) type {
    return struct {
        app: *app_mod.App(State),
        kq: c_int_t,
        pipe_read: c_int_t,
        send_buf: [send_cap]u8 = undefined,
        worker_id: usize,
    };
}

// ---------------------- Public entry point -------------------------------

pub fn serve(comptime State: type, app: *app_mod.App(State), opts: app_mod.ServeOptions) !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .ios and
        builtin.os.tag != .freebsd and builtin.os.tag != .netbsd and
        builtin.os.tag != .openbsd and builtin.os.tag != .dragonfly)
    {
        std.log.err("reactor_kqueue: requires a BSD-family kernel (got {s})", .{@tagName(builtin.os.tag)});
        return error.UnsupportedPlatform;
    }

    const addr_str = opts.address orelse "0.0.0.0";
    const ip = parseIpv4(addr_str) catch |e| {
        std.log.err("invalid bind address {s}: {t}", .{ addr_str, e });
        return error.InvalidAddress;
    };

    const listen_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_fd < 0) return error.SocketFailed;
    defer _ = close(listen_fd);

    const yes: c_int_t = 1;
    _ = setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&yes), @sizeOf(c_int_t));
    _ = setsockopt(listen_fd, SOL_SOCKET, SO_REUSEPORT, @ptrCast(&yes), @sizeOf(c_int_t));

    var sin: SockAddrIn = .{ .sin_port = htons(opts.port), .sin_addr = ip };
    if (bind(listen_fd, &sin, @sizeOf(SockAddrIn)) != 0) {
        std.log.err("bind() failed: errno {d}", .{errnoVal()});
        return error.BindFailed;
    }
    if (listen(listen_fd, 1024) != 0) return error.ListenFailed;
    app.listener_fd.store(listen_fd, .seq_cst);

    // --- Per-worker setup ---
    const worker_count = opts.worker_count orelse blk: {
        const n = std.Thread.getCpuCount() catch 4;
        break :blk n;
    };
    std.log.info("akamata (reactor_kqueue, workers={d}) listening on http://{s}:{d}/", .{ worker_count, addr_str, opts.port });

    const Ctx = WorkerCtx(State);
    var worker_ctxs: std.ArrayList(*Ctx) = .empty;
    defer {
        for (worker_ctxs.items) |c| {
            _ = close(c.pipe_read);
            _ = close(c.kq);
            app.gpa.destroy(c);
        }
        worker_ctxs.deinit(app.gpa);
    }
    try worker_ctxs.ensureTotalCapacity(app.gpa, worker_count);

    var pipe_writes: std.ArrayList(c_int_t) = .empty;
    defer pipe_writes.deinit(app.gpa);
    try pipe_writes.ensureTotalCapacity(app.gpa, worker_count);

    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(app.gpa);
    try threads.ensureTotalCapacity(app.gpa, worker_count);

    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        var fds: [2]c_int_t = .{ 0, 0 };
        if (pipe(&fds) != 0) return error.PipeFailed;
        try setNonBlocking(fds[0]);
        try setNonBlocking(fds[1]);

        const kq = kqueue();
        if (kq < 0) return error.KqueueFailed;

        const c = try app.gpa.create(Ctx);
        c.* = .{
            .app = app,
            .kq = kq,
            .pipe_read = fds[0],
            .worker_id = i,
        };
        worker_ctxs.appendAssumeCapacity(c);
        pipe_writes.appendAssumeCapacity(fds[1]);

        const t = try std.Thread.spawn(.{}, workerLoop, .{ State, c });
        threads.appendAssumeCapacity(t);
    }

    // --- Accept loop on the main thread (acceptor) ---
    var next_worker: usize = 0;
    while (!app.shutdown_flag.load(.seq_cst)) {
        const cfd = accept(listen_fd, null, null);
        if (cfd < 0) {
            const e = errnoVal();
            if (e == 4) continue; // EINTR
            if (isEagain(e)) continue;
            std.log.warn("accept failed: errno {d}", .{e});
            continue;
        }
        // Hand the fd to a worker by writing 4 bytes into its pipe.
        const target = pipe_writes.items[next_worker];
        next_worker = (next_worker + 1) % worker_count;
        const buf: [4]u8 = @bitCast(cfd);
        const w = write(target, &buf, 4);
        if (w != 4) {
            std.log.warn("dispatch to worker failed: rc={d} errno={d}", .{ w, errnoVal() });
            _ = close(cfd);
        }
    }

    // Close pipe writes to wake workers blocked on kqueue.
    for (pipe_writes.items) |fd| _ = close(fd);
    for (threads.items) |t| t.join();
}

fn setNonBlocking(fd: c_int_t) !void {
    const flags = fcntl(fd, F_GETFL, @as(c_int_t, 0));
    if (flags < 0) return error.FcntlFailed;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return error.FcntlFailed;
}

// ---------------------- Per-worker event loop ----------------------------

fn workerLoop(comptime State: type, ctx: *WorkerCtx(State)) void {
    // Register the pipe as the wakeup source for new fd handoffs.
    var change: Kevent = .{
        .ident = @intCast(ctx.pipe_read),
        .filter = EVFILT_READ,
        .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    if (kevent(ctx.kq, @ptrCast(&change), 1, null, 0, null) != 0) {
        std.log.err("worker {d}: kevent register pipe failed: errno {d}", .{ ctx.worker_id, errnoVal() });
        return;
    }

    var conns: std.AutoHashMap(c_int_t, *Conn) = .init(ctx.app.gpa);
    defer {
        var it = conns.iterator();
        while (it.next()) |kv| kv.value_ptr.*.deinit(ctx.app.gpa);
        conns.deinit();
    }

    var events: [128]Kevent = undefined;
    while (!ctx.app.shutdown_flag.load(.seq_cst)) {
        const n = kevent(ctx.kq, null, 0, &events, events.len, null);
        if (n < 0) {
            const e = errnoVal();
            if (e == 4) continue;
            std.log.err("worker {d}: kevent wait failed: errno {d}", .{ ctx.worker_id, e });
            break;
        }
        var j: usize = 0;
        while (j < @as(usize, @intCast(n))) : (j += 1) {
            const ev = events[j];
            const fd: c_int_t = @intCast(ev.ident);
            if (fd == ctx.pipe_read) {
                onPipeReadable(State, ctx, &conns);
            } else if (ev.flags & EV_EOF != 0 or ev.flags & EV_ERROR != 0) {
                closeConn(State, ctx, &conns, fd);
            } else if (ev.filter == EVFILT_READ) {
                onConnReadable(State, ctx, &conns, fd);
            }
        }
    }
}

fn onPipeReadable(
    comptime State: type,
    ctx: *WorkerCtx(State),
    conns: *std.AutoHashMap(c_int_t, *Conn),
) void {
    // Drain all queued fds. Each message is exactly 4 bytes (a c_int).
    var buf: [4]u8 = undefined;
    while (true) {
        const r = read(ctx.pipe_read, &buf, 4);
        if (r == 4) {
            const cfd: c_int_t = @bitCast(buf);
            setNonBlocking(cfd) catch {
                _ = close(cfd);
                continue;
            };
            const yes: c_int_t = 1;
            _ = setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, @ptrCast(&yes), @sizeOf(c_int_t));

            const conn = Conn.init(ctx.app.gpa, cfd) catch {
                _ = close(cfd);
                continue;
            };
            conns.put(cfd, conn) catch {
                conn.deinit(ctx.app.gpa);
                continue;
            };
            // Edge-triggered: we'll drain the socket each time we wake.
            var ch: Kevent = .{
                .ident = @intCast(cfd),
                .filter = EVFILT_READ,
                .flags = EV_ADD | EV_ENABLE | EV_CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            if (kevent(ctx.kq, @ptrCast(&ch), 1, null, 0, null) != 0) {
                _ = conns.remove(cfd);
                conn.deinit(ctx.app.gpa);
            }
        } else if (r == 0) {
            return; // pipe closed → shutdown will catch this next loop
        } else {
            if (isEagain(errnoVal())) return;
            return;
        }
    }
}

fn onConnReadable(
    comptime State: type,
    ctx: *WorkerCtx(State),
    conns: *std.AutoHashMap(c_int_t, *Conn),
    fd: c_int_t,
) void {
    const conn = conns.get(fd) orelse return;
    // Drain everything available (EV_CLEAR semantics).
    while (true) {
        if (conn.pending == recv_cap) {
            closeConn(State, ctx, conns, fd);
            return;
        }
        const room = recv_cap - conn.pending;
        const r = read(fd, conn.recv_buf[conn.pending..].ptr, room);
        if (r > 0) {
            conn.pending += @intCast(r);
        } else if (r == 0) {
            closeConn(State, ctx, conns, fd);
            return;
        } else {
            if (!isEagain(errnoVal())) {
                closeConn(State, ctx, conns, fd);
                return;
            }
            break;
        }
    }
    // Process whatever complete requests we now have.
    processConn(State, ctx, conns, conn) catch {
        closeConn(State, ctx, conns, fd);
    };
}

fn processConn(
    comptime State: type,
    ctx: *WorkerCtx(State),
    conns: *std.AutoHashMap(c_int_t, *Conn),
    conn: *Conn,
) !void {
    while (conn.pending > 0) {
        _ = conn.arena_state.reset(.retain_capacity);
        const arena = conn.arena_state.allocator();

        if (parser.headersEnd(conn.recv_buf[0..conn.pending]) == null) break;

        const parsed = parser.parseRequest(arena, conn.recv_buf[0..conn.pending], .{}) catch |e| switch (e) {
            parser.ParseError.Incomplete => break,
            else => return e,
        };

        var req_local = parsed.request;
        var res: res_mod.Response = .init(arena);
        res.keep_alive = req_local.keep_alive;

        ctx.app.dispatch(arena, &req_local, &res, null, null) catch {};

        try writeResponse(WorkerCtx(State), ctx, conn.fd, &res, arena);

        const total = parsed.consumed;
        if (total < conn.pending) {
            std.mem.copyForwards(u8, conn.recv_buf[0 .. conn.pending - total], conn.recv_buf[total..conn.pending]);
            conn.pending -= total;
        } else {
            conn.pending = 0;
        }
        if (!res.keep_alive or res.is_upgrade) {
            closeConn(State, ctx, conns, conn.fd);
            return;
        }
    }
}

/// Serialise the response and send it. Hot path: try the worker-local
/// 16 KB stack buffer first; only fall back to the arena when the
/// response doesn't fit. This skips one allocator round-trip per request
/// for typical JSON responses (PERF8).
fn writeResponse(
    comptime CtxT: type,
    ctx: *CtxT,
    fd: c_int_t,
    res: *res_mod.Response,
    arena: std.mem.Allocator,
) !void {
    // Try writing into the per-worker scratch buffer.
    var fbs = std.Io.Writer.fixed(&ctx.send_buf);
    if (writeIntoFixed(&fbs, res)) {
        try sendAll(fd, fbs.buffered());
        return;
    }
    // Doesn't fit — fall back to arena. This path is rare for typical
    // API responses (large file downloads / huge JSON only).
    var alloc_w: std.Io.Writer.Allocating = .init(arena);
    try res.writeTo(&alloc_w.writer);
    try sendAll(fd, alloc_w.writer.buffered());
}

/// Returns true if the response fit entirely into the fixed buffer.
fn writeIntoFixed(fbs: *std.Io.Writer, res: *res_mod.Response) bool {
    res.writeTo(fbs) catch return false;
    return true;
}

fn sendAll(fd: c_int_t, buf: []const u8) !void {
    var sent: usize = 0;
    while (sent < buf.len) {
        const w = write(fd, buf[sent..].ptr, buf.len - sent);
        if (w > 0) {
            sent += @intCast(w);
        } else if (w < 0) {
            if (isEagain(errnoVal())) continue;
            return error.WriteFailed;
        } else break;
    }
}

fn closeConn(
    comptime State: type,
    ctx: *WorkerCtx(State),
    conns: *std.AutoHashMap(c_int_t, *Conn),
    fd: c_int_t,
) void {
    if (conns.fetchRemove(fd)) |kv| kv.value.deinit(ctx.app.gpa);
}
