// Linux epoll counterpart to `reactor_kqueue.zig` (PERF4 + PERF7).
//
// Same per-worker thread-per-core layout as the kqueue version:
//
//   * 1 acceptor thread on blocking accept(2) → write fd to worker pipe
//   * N worker threads, each owns its own epoll fd + conn map
//   * No cross-worker shared state
//
// See `reactor_kqueue.zig` for the full architecture comments.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const req_mod = @import("../http/request.zig");
const res_mod = @import("../http/response.zig");
const parser = @import("../http/parser.zig");

// ---------------------- libc bindings (Linux) ----------------------------

const c_int_t = c_int;

const SOCK_STREAM: c_int_t = 1;
const SOCK_CLOEXEC: c_int_t = 0o02000000;
const SOCK_NONBLOCK: c_int_t = 0o00004000;
const AF_INET: c_int_t = 2;
const IPPROTO_TCP: c_int_t = 6;
const SOL_SOCKET: c_int_t = 1;
const SO_REUSEADDR: c_int_t = 2;
const SO_REUSEPORT: c_int_t = 15;
const TCP_NODELAY: c_int_t = 1;
const F_GETFL: c_int_t = 3;
const F_SETFL: c_int_t = 4;
const O_NONBLOCK: c_int_t = 0o00004000;
const O_CLOEXEC: c_int_t = 0o02000000;

const EPOLL_CLOEXEC: c_int_t = 0o02000000;
const EPOLL_CTL_ADD: c_int_t = 1;
const EPOLL_CTL_DEL: c_int_t = 2;
const EPOLL_CTL_MOD: c_int_t = 3;

const EPOLLIN: u32 = 0x001;
const EPOLLET: u32 = 0x80000000;
const EPOLLHUP: u32 = 0x010;
const EPOLLERR: u32 = 0x008;
const EPOLLRDHUP: u32 = 0x2000;

const SockAddrIn = extern struct {
    sin_family: u16 = AF_INET,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

const EpollData = extern union {
    ptr: ?*anyopaque,
    fd: c_int_t,
    u32_val: u32,
    u64_val: u64,
};

const EpollEvent = extern struct {
    events: u32,
    data: EpollData,
};

extern "c" fn socket(domain: c_int_t, sock_type: c_int_t, protocol: c_int_t) c_int_t;
extern "c" fn setsockopt(fd: c_int_t, level: c_int_t, optname: c_int_t, optval: *const anyopaque, optlen: u32) c_int_t;
extern "c" fn bind(fd: c_int_t, addr: *const SockAddrIn, len: u32) c_int_t;
extern "c" fn listen(fd: c_int_t, backlog: c_int_t) c_int_t;
extern "c" fn accept4(fd: c_int_t, addr: ?*anyopaque, addrlen: ?*u32, flags: c_int_t) c_int_t;
extern "c" fn close(fd: c_int_t) c_int_t;
extern "c" fn read(fd: c_int_t, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int_t, buf: [*]const u8, count: usize) isize;
extern "c" fn fcntl(fd: c_int_t, cmd: c_int_t, ...) c_int_t;
extern "c" fn pipe2(fds: [*]c_int_t, flags: c_int_t) c_int_t;
extern "c" fn epoll_create1(flags: c_int_t) c_int_t;
extern "c" fn epoll_ctl(epfd: c_int_t, op: c_int_t, fd: c_int_t, event: ?*EpollEvent) c_int_t;
extern "c" fn epoll_wait(epfd: c_int_t, events: [*]EpollEvent, maxevents: c_int_t, timeout: c_int_t) c_int_t;
extern "c" fn __errno_location() *c_int_t;

inline fn errnoVal() c_int_t {
    return __errno_location().*;
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
    return e == 11; // EAGAIN == EWOULDBLOCK on Linux
}

// ---------------------- Per-connection state -----------------------------

const recv_cap = 16 * 1024;
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

fn WorkerCtx(comptime State: type) type {
    return struct {
        app: *app_mod.App(State),
        epfd: c_int_t,
        pipe_read: c_int_t,
        send_buf: [send_cap]u8 = undefined,
        worker_id: usize,
    };
}

// ---------------------- Public entry point -------------------------------

pub fn serve(comptime State: type, app: *app_mod.App(State), opts: app_mod.ServeOptions) !void {
    if (builtin.os.tag != .linux) {
        std.log.err("reactor_epoll: requires Linux (got {s})", .{@tagName(builtin.os.tag)});
        return error.UnsupportedPlatform;
    }

    const addr_str = opts.address orelse "0.0.0.0";
    const ip = parseIpv4(addr_str) catch |e| {
        std.log.err("invalid bind address {s}: {t}", .{ addr_str, e });
        return error.InvalidAddress;
    };

    const listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, IPPROTO_TCP);
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

    const worker_count = opts.worker_count orelse blk: {
        const n = std.Thread.getCpuCount() catch 4;
        break :blk n;
    };
    std.log.info("akamata (reactor_epoll, workers={d}) listening on http://{s}:{d}/", .{ worker_count, addr_str, opts.port });

    const Ctx = WorkerCtx(State);
    var worker_ctxs: std.ArrayList(*Ctx) = .empty;
    defer {
        for (worker_ctxs.items) |c| {
            _ = close(c.pipe_read);
            _ = close(c.epfd);
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
        if (pipe2(&fds, O_NONBLOCK | O_CLOEXEC) != 0) return error.PipeFailed;

        const epfd = epoll_create1(EPOLL_CLOEXEC);
        if (epfd < 0) return error.EpollFailed;

        const c = try app.gpa.create(Ctx);
        c.* = .{
            .app = app,
            .epfd = epfd,
            .pipe_read = fds[0],
            .worker_id = i,
        };
        worker_ctxs.appendAssumeCapacity(c);
        pipe_writes.appendAssumeCapacity(fds[1]);

        const t = try std.Thread.spawn(.{}, workerLoop, .{ State, c });
        threads.appendAssumeCapacity(t);
    }

    // --- Accept loop on the main thread ---
    var next_worker: usize = 0;
    while (!app.shutdown_flag.load(.seq_cst)) {
        const cfd = accept4(listen_fd, null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (cfd < 0) {
            const e = errnoVal();
            if (e == 4) continue;
            if (isEagain(e)) continue;
            std.log.warn("accept failed: errno {d}", .{e});
            continue;
        }
        const target = pipe_writes.items[next_worker];
        next_worker = (next_worker + 1) % worker_count;
        const buf: [4]u8 = @bitCast(cfd);
        const w = write(target, &buf, 4);
        if (w != 4) {
            _ = close(cfd);
        }
    }

    for (pipe_writes.items) |fd| _ = close(fd);
    for (threads.items) |t| t.join();
}

// ---------------------- Per-worker event loop ----------------------------

fn workerLoop(comptime State: type, ctx: *WorkerCtx(State)) void {
    // Register the pipe for ET reads.
    var ev: EpollEvent = .{
        .events = EPOLLIN | EPOLLET,
        .data = .{ .fd = ctx.pipe_read },
    };
    if (epoll_ctl(ctx.epfd, EPOLL_CTL_ADD, ctx.pipe_read, &ev) != 0) {
        std.log.err("worker {d}: epoll_ctl(pipe) failed: errno {d}", .{ ctx.worker_id, errnoVal() });
        return;
    }

    var conns: std.AutoHashMap(c_int_t, *Conn) = .init(ctx.app.gpa);
    defer {
        var it = conns.iterator();
        while (it.next()) |kv| kv.value_ptr.*.deinit(ctx.app.gpa);
        conns.deinit();
    }

    var events: [128]EpollEvent = undefined;
    while (!ctx.app.shutdown_flag.load(.seq_cst)) {
        const n = epoll_wait(ctx.epfd, &events, events.len, 1000);
        if (n < 0) {
            const e = errnoVal();
            if (e == 4) continue;
            break;
        }
        var j: usize = 0;
        while (j < @as(usize, @intCast(n))) : (j += 1) {
            const e = events[j];
            const fd = e.data.fd;
            if (fd == ctx.pipe_read) {
                onPipeReadable(State, ctx, &conns);
            } else {
                const hup = (e.events & (EPOLLHUP | EPOLLERR | EPOLLRDHUP)) != 0;
                if (hup) {
                    closeConn(State, ctx, &conns, fd);
                } else if ((e.events & EPOLLIN) != 0) {
                    onConnReadable(State, ctx, &conns, fd);
                }
            }
        }
    }
}

fn onPipeReadable(
    comptime State: type,
    ctx: *WorkerCtx(State),
    conns: *std.AutoHashMap(c_int_t, *Conn),
) void {
    var buf: [4]u8 = undefined;
    while (true) {
        const r = read(ctx.pipe_read, &buf, 4);
        if (r == 4) {
            const cfd: c_int_t = @bitCast(buf);
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
            var ev: EpollEvent = .{
                .events = EPOLLIN | EPOLLET | EPOLLRDHUP,
                .data = .{ .fd = cfd },
            };
            if (epoll_ctl(ctx.epfd, EPOLL_CTL_ADD, cfd, &ev) != 0) {
                _ = conns.remove(cfd);
                conn.deinit(ctx.app.gpa);
            }
        } else if (r == 0) {
            return;
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

fn writeResponse(
    comptime CtxT: type,
    ctx: *CtxT,
    fd: c_int_t,
    res: *res_mod.Response,
    arena: std.mem.Allocator,
) !void {
    var fbs = std.Io.Writer.fixed(&ctx.send_buf);
    if (writeIntoFixed(&fbs, res)) {
        try sendAll(fd, fbs.buffered());
        return;
    }
    var alloc_w: std.Io.Writer.Allocating = .init(arena);
    try res.writeTo(&alloc_w.writer);
    try sendAll(fd, alloc_w.writer.buffered());
}

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
