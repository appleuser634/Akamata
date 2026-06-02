// `app.serve()` implementation: dispatches to a native HTTP server or to the
// Workers WASM bridge based on `build_options.backend`.

const std = @import("std");
const build_options = @import("build_options");
const app_mod = @import("app.zig");
const req_mod = @import("http/request.zig");
const res_mod = @import("http/response.zig");
const parser = @import("http/parser.zig");

const is_native = build_options.backend == .native;
const Io = std.Io;
const net = std.Io.net;

pub fn serve(comptime State: type, app: *app_mod.App(State), opts: app_mod.ServeOptions) !void {
    if (is_native) {
        switch (opts.runtime) {
            .threaded => return serveNative(State, app, opts),
            .reactor => {
                if (comptime @import("builtin").os.tag == .linux) {
                    return @import("runtime/reactor_epoll.zig").serve(State, app, opts);
                }
                return @import("runtime/reactor_kqueue.zig").serve(State, app, opts);
            },
        }
    }
    return serveWorkers(State, app, opts);
}

// =========================================================================
// Native: std.Io.Threaded + std.Io.net listener
// =========================================================================

fn serveNative(comptime State: type, app: *app_mod.App(State), opts: app_mod.ServeOptions) !void {
    if (!is_native) return;
    var io_impl: Io.Threaded = .init(app.gpa, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    const addr_str = opts.address orelse "0.0.0.0";
    var addr = net.IpAddress.parseIp4(addr_str, opts.port) catch {
        std.log.err("invalid bind address {s}: must be an IPv4 literal", .{addr_str});
        return error.InvalidAddress;
    };
    var listener = try net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    defer {
        app.listener_fd.store(-1, .seq_cst);
        listener.deinit(io);
    }

    app.listener_fd.store(listener.socket.handle, .seq_cst);
    // Put the listener in non-blocking mode. The accept loop uses libc
    // accept(2) directly (not std.Io), so EAGAIN is just an errno we loop on —
    // no thread ever blocks inside accept(), which is what made shutdown(2) /
    // Ctrl-C unable to stop the server before. Readiness is waited on via
    // poll(2) with a timeout that bounds shutdown latency.
    setNonBlocking(listener.socket.handle);
    std.log.info("akamata listening on http://{s}:{d}/", .{ addr_str, opts.port });

    const n_threads = @max(opts.accept_thread_count, 1);
    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(app.gpa);
    try threads.ensureTotalCapacity(app.gpa, n_threads);

    const Ctx = LoopCtx(State);
    var ctx: Ctx = .{ .app = app, .io = io, .listener = &listener, .opts = &opts };

    installSignalHandlers(State, app);

    var i: usize = 1;
    while (i < n_threads) : (i += 1) {
        const t = try std.Thread.spawn(.{}, acceptLoopThread, .{ State, &ctx });
        threads.appendAssumeCapacity(t);
    }
    acceptLoop(State, &ctx);
    for (threads.items) |t| t.join();
}

fn LoopCtx(comptime State: type) type {
    return struct {
        app: *app_mod.App(State),
        io: Io,
        listener: *net.Server,
        opts: *const app_mod.ServeOptions,
    };
}

fn acceptLoopThread(comptime State: type, ctx: *LoopCtx(State)) void {
    acceptLoop(State, ctx);
}

fn acceptLoop(comptime State: type, ctx: *LoopCtx(State)) void {
    // Exponential backoff for transient accept failures (EMFILE, ENFILE,
    // ENOBUFS, etc.). Doubles from 100us up to 5s, resets on a successful
    // accept. Without this a server out of fds spins at 100% CPU spamming
    // the log.
    var backoff_us: u64 = 0;
    const max_backoff_us: u64 = 5_000_000;
    const Lib = struct {
        extern "c" fn usleep(usecs: c_uint) c_int;
    };

    // We deliberately do NOT use the listener's std.Io accept() here. Under
    // Zig 0.16, std.Io.Threaded parks in a blocking accept() that shutdown(2)
    // does not wake (so Ctrl-C left accept threads hung at join() forever), and
    // a non-blocking listener makes that same accept() *panic* on EAGAIN via
    // its `errnoBug`. Instead we poll(2) the listener fd with a timeout and,
    // once readable, call libc accept(2) directly, wrapping the raw fd into a
    // net.Stream. poll's timeout guarantees every thread re-checks the
    // shutdown flag promptly, so requestShutdown() / Ctrl-C always stops them.
    //
    // accept_poll_ms bounds how long a parked thread can ignore shutdown_flag.
    const accept_poll_ms: c_int = 250;

    while (!ctx.app.shutdown_flag.load(.seq_cst)) {
        const fd = ctx.app.listener_fd.load(.seq_cst);
        if (fd < 0) return;
        if (!waitAcceptReady(fd, accept_poll_ms)) continue; // timeout/EINTR → re-check flag
        if (ctx.app.shutdown_flag.load(.seq_cst)) return;

        const cfd = rawAccept(fd);
        if (cfd < 0) {
            // EAGAIN/EWOULDBLOCK: another thread took it, or a spurious wakeup.
            // EINVAL/EBADF: listener was shut down. Either way, loop and let the
            // flag check / next poll handle it. Brief backoff on hard errors.
            const e = errnoVal();
            if (e == EAGAIN or e == EWOULDBLOCK or e == ECONNABORTED or e == EINTR) continue;
            if (ctx.app.shutdown_flag.load(.seq_cst)) return;
            std.log.warn("accept failed: errno {d} (backoff {d}us)", .{ e, backoff_us });
            if (backoff_us > 0) _ = Lib.usleep(@intCast(backoff_us));
            backoff_us = if (backoff_us == 0) 100 else @min(backoff_us * 2, max_backoff_us);
            continue;
        }
        backoff_us = 0;
        // The connection fd may inherit O_NONBLOCK from the listener; std.Io's
        // read/write path requires blocking fds, so force it back.
        setBlocking(cfd);
        const stream: net.Stream = .{ .socket = .{ .handle = cfd, .address = undefined } };
        applyTimeouts(stream, ctx.opts) catch {};
        applyTcpNoDelay(stream) catch {};
        handleConnection(State, ctx.app, ctx.io, stream) catch |err| switch (err) {
            // OOM in a per-connection arena should not crash the worker; the
            // peer already saw its socket get closed by the defer above, so
            // we just log and keep accepting.
            error.OutOfMemory => std.log.err("conn aborted: OOM", .{}),
            else => std.log.err("conn error: {t}", .{err}),
        };
    }
}

// === Socket-level timeout configuration ===
//
// HISTORICAL NOTE: we used to set SO_RCVTIMEO / SO_SNDTIMEO on each accepted
// TCP socket as a slowloris defense — peers stuck in a half-open send would
// then trip EAGAIN on read, which we wanted to surface as `error.Timeout`.
//
// That approach is incompatible with Zig 0.16's std.Io.Threaded: its
// `netReadPosix` treats EAGAIN as a *programmer bug* (the std assumes the
// fd is blocking-mode and that EAGAIN can only come from a missed non-block
// flag) and panics through `errnoBug` in debug builds. The thread crash
// reproduced cleanly from a real client timing out on a long-lived
// keep-alive connection.
//
// We therefore no longer flip those socket options. Slowloris defense
// should live one layer out (Cloudflare / reverse proxy / IPv4 firewall
// rate limit / OS keepalive). The `read_timeout_ms` / `write_timeout_ms`
// fields on `ServeOptions` are kept for future re-introduction via a
// non-stdlib read path; setting them is currently a no-op.
const builtin = @import("builtin");

extern "c" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;

// === Shutdown-aware accept ===
//
// `std.Io.Threaded`'s blocking accept() does not reliably wake up when
// `requestShutdown()` calls `shutdown(2)` on the listener fd, so the accept
// loop could hang forever after Ctrl-C / SIGTERM and the process had to be
// SIGKILL'd. Worse, a non-blocking listener makes std's accept() *panic* on
// EAGAIN (errnoBug).
//
// So we bypass std.Io for accept entirely: the listener is non-blocking, each
// thread waits for readability with poll(2) (timeout bounds shutdown latency),
// then calls libc accept(2) directly — where EAGAIN is an ordinary errno we
// loop on, and shutdown(2) surfaces as EBADF/EINVAL so the loop exits. The
// accepted connection fd is switched back to blocking before being handed to
// std.Io.Threaded's read/write path (which itself asserts on EAGAIN).
const PollFd = extern struct {
    fd: c_int,
    events: i16,
    revents: i16 = 0,
};
const POLLIN: i16 = 0x0001;
extern "c" fn poll(fds: [*]PollFd, nfds: c_uint, timeout_ms: c_int) c_int;
extern "c" fn accept(sockfd: c_int, addr: ?*anyopaque, addrlen: ?*u32) c_int;
extern "c" fn __error() *c_int; // macOS/BSD errno location
extern "c" fn __errno_location() *c_int; // Linux errno location
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;

const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = if (builtin.os.tag == .macos or builtin.os.tag == .ios) 0x0004 else 0o4000;

/// Set O_NONBLOCK on a socket fd (best effort).
fn setNonBlocking(fd: c_int) void {
    const flags = fcntl(fd, F_GETFL);
    if (flags < 0) return;
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/// Clear O_NONBLOCK so the fd is blocking again (best effort). Accepted
/// connection fds must be blocking: std.Io.Threaded's read/write path treats
/// EAGAIN as a programmer bug and panics in debug builds.
fn setBlocking(fd: c_int) void {
    const flags = fcntl(fd, F_GETFL);
    if (flags < 0) return;
    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
}

const EINTR: c_int = 4;
const EBADF: c_int = 9;
const EAGAIN: c_int = if (builtin.os.tag == .linux) 11 else 35;
const EWOULDBLOCK: c_int = EAGAIN;
const ECONNABORTED: c_int = if (builtin.os.tag == .linux) 103 else 53;

fn errnoVal() c_int {
    return switch (builtin.os.tag) {
        .linux => __errno_location().*,
        else => __error().*,
    };
}

/// Block up to `timeout_ms` waiting for the listener to have an incoming
/// connection. Returns true if a connection is (probably) ready to accept,
/// false on timeout/EINTR/error so the caller re-checks `shutdown_flag`.
fn waitAcceptReady(fd: c_int, timeout_ms: c_int) bool {
    var pfd = [_]PollFd{.{ .fd = fd, .events = POLLIN }};
    return poll(&pfd, 1, timeout_ms) > 0;
}

/// libc accept(2) on the raw listener fd. Returns the connection fd, or a
/// negative value on error (inspect errnoVal()).
fn rawAccept(fd: c_int) c_int {
    return accept(fd, null, null);
}

// === Signal handlers for graceful shutdown ===
//
// We can't go through std.posix.sigaction in 0.16 because its `handler_fn`
// argument type is architecture-specific (some platforms expose `c_int`,
// others a SIG enum). Calling libc `signal(3)` directly with the simple
// `void (*)(int)` form gives us a portable hookup and is enough for
// "stop accepting on Ctrl-C".

const SignalHandler = *const fn (sig: c_int) callconv(.c) void;
extern "c" fn signal(sig: c_int, h: SignalHandler) SignalHandler;

const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
const SIGPIPE: c_int = 13;
const SIG_IGN: usize = 1;

const ShutdownRegistry = struct {
    var slot: ?*anyopaque = null;
    var trigger: ?*const fn (*anyopaque) void = null;
};

fn noopHandler(_: c_int) callconv(.c) void {}

fn shutdownTrampoline(_: c_int) callconv(.c) void {
    if (ShutdownRegistry.slot) |s| {
        if (ShutdownRegistry.trigger) |t| t(s);
    }
}

fn installSignalHandlers(comptime State: type, app: *app_mod.App(State)) void {
    if (builtin.os.tag == .windows) return;
    const Wrap = struct {
        fn trigger(opaque_app: *anyopaque) void {
            const a: *app_mod.App(State) = @ptrCast(@alignCast(opaque_app));
            a.requestShutdown();
        }
    };
    ShutdownRegistry.slot = @ptrCast(app);
    ShutdownRegistry.trigger = Wrap.trigger;
    _ = signal(SIGINT, shutdownTrampoline);
    _ = signal(SIGTERM, shutdownTrampoline);
    // Avoid the whole process dying when a peer closes mid-write.
    // We register a no-op handler instead of SIG_IGN to dodge the 0.16
    // alignment check on the synthetic SIG_IGN pointer (=1).
    _ = signal(SIGPIPE, noopHandler);
}

/// Disable Nagle's algorithm so small responses go out immediately. HTTP/1.1
/// keep-alive workloads dominated by 100-byte requests/responses see noticeably
/// lower P99 latency once this is on.
fn applyTcpNoDelay(stream: net.Stream) !void {
    if (!is_native) return;
    if (builtin.os.tag == .windows) return;
    const IPPROTO_TCP: c_int = 6;
    const TCP_NODELAY: c_int = 1;
    const fd: c_int = stream.socket.handle;
    const on: c_int = 1;
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, @ptrCast(&on), @sizeOf(c_int));
}

fn applyTimeouts(stream: net.Stream, opts: *const app_mod.ServeOptions) !void {
    // Intentionally a no-op — see the multi-paragraph note above for why
    // SO_RCVTIMEO/SO_SNDTIMEO are off the table while we depend on
    // std.Io.Threaded.netReadPosix.
    _ = stream;
    _ = opts;
}

fn handleConnection(comptime State: type, app: *app_mod.App(State), io: Io, stream: net.Stream) !void {
    var owns_stream = true;
    defer if (owns_stream) stream.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();

    const recv_cap: usize = 16 * 1024;
    const recv_buf = try app.gpa.alloc(u8, recv_cap);
    defer app.gpa.free(recv_buf);

    var sock_reader_buf: [4096]u8 = undefined;
    var sr = stream.reader(io, &sock_reader_buf);
    const r: *Io.Reader = &sr.interface;

    var pending_len: usize = 0;
    keep_alive: while (true) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();

        while (parser.headersEnd(recv_buf[0..pending_len]) == null) {
            if (pending_len == recv_buf.len) return error.HeadersTooLarge;
            var vec: [1][]u8 = .{recv_buf[pending_len..]};
            const n = r.readVec(&vec) catch return;
            if (n == 0) return;
            pending_len += n;
        }

        const parsed = blk: while (true) {
            const p = parser.parseRequest(arena, recv_buf[0..pending_len], .{}) catch |e| switch (e) {
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

        var req_local = parsed.request;
        var res: res_mod.Response = .init(arena);
        res.keep_alive = req_local.keep_alive;

        // Pre-create the socket writer so streaming handlers can grab it
        // via `res.startStream()`.
        var sock_writer_buf: [4096]u8 = undefined;
        var sw = stream.writer(io, &sock_writer_buf);
        const w: *Io.Writer = &sw.interface;
        res.socket_writer = w;

        app.dispatch(
            arena,
            &req_local,
            &res,
            @ptrCast(@constCast(&stream)),
            @ptrCast(@constCast(&io)),
        ) catch |err| {
            // The middleware chain catches handler errors and turns them
            // into 5xx for *buffered* responses. Streaming responses are
            // different: headers + partial chunks have already left the
            // building, so the best we can do is finalize the stream
            // cleanly (0-chunk + flush) so the client sees EOF instead
            // of a dangling read. Then bail.
            if (res.streaming) |cw| {
                std.log.warn("streaming handler returned error mid-stream: {t}", .{err});
                cw.end() catch {};
                w.flush() catch {};
                return;
            }
            // Buffered: re-raise so the surrounding code path can pick
            // it up (mirrors the original `try` behavior).
            return err;
        };

        if (res.is_upgrade) {
            owns_stream = false;
            return;
        }

        // Streaming path: handler already pushed headers + chunks to `w`;
        // we just need to write the terminating 0-chunk and flush.
        if (res.streaming) |cw| {
            cw.end() catch return;
            w.flush() catch return;
            return;
        }

        // Buffered path: single-shot serialise then write.
        //
        // We tried writing res.writeTo directly into a 16 KB-buffered
        // socket writer in early 2026; results were within ±5% of this
        // path on a hot loopback. The arena-allocate-then-send pattern
        // wins on consistency because the kernel sees one contiguous
        // payload (better for the TLS/proxy cases too).
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

// =========================================================================
// Workers: register the dispatch with the WASM runtime
// =========================================================================

const runtime_workers = if (build_options.backend == .workers) @import("runtime/workers.zig") else struct {};

fn serveWorkers(comptime State: type, app: *app_mod.App(State), opts: app_mod.ServeOptions) !void {
    _ = opts;
    if (is_native) return;
    const Wrap = struct {
        var app_ref: *app_mod.App(State) = undefined;
        fn dispatch(request_bytes: []const u8, out: *std.ArrayList(u8)) anyerror!void {
            const gpa = std.heap.wasm_allocator;
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const parsed = try parser.parseRequest(arena, request_bytes, .{});
            var req_local = parsed.request;
            var res: res_mod.Response = .init(arena);
            res.keep_alive = false;

            try app_ref.dispatch(arena, &req_local, &res, null, null);

            var aw: Io.Writer.Allocating = .fromArrayList(gpa, out);
            defer out.* = aw.toArrayList();
            try res.writeTo(&aw.writer);
        }
    };
    Wrap.app_ref = app;
    runtime_workers.setDispatch(Wrap.dispatch);
    // Hand control back; the JS host invokes `handle_fetch` per request.
}
