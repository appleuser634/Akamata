// In-process rate limiting using a fixed-window counter keyed by an
// arbitrary string (typically the client IP or authenticated user id).
//
// Behaviour: each key gets a counter that resets every `window_secs`.
// Requests after `max_requests` in the same window are rejected with 429.
// Counters live in a single hash map guarded by a mutex; this is plenty
// for tens of thousands of req/s on one box. For multi-process / multi-node
// deployments, plug in a Redis / Durable-Object backed Store via the
// (future) `Store` interface — the in-memory variant is the default.

const std = @import("std");
const app_mod = @import("../app.zig");
const sync = @import("../sync.zig");

const Entry = struct {
    window_start: i64,
    count: u32,
};

pub fn Options(comptime State: type) type {
    return struct {
        /// Returns the rate-limit key for this request. Most callers will
        /// return `c.req.ip() orelse "anon"`.
        key_fn: *const fn (c: *app_mod.App(State).Ctx) []const u8,
        max_requests: u32 = 60,
        window_secs: u32 = 60,
        /// If true, attach `X-RateLimit-*` headers on every response.
        emit_headers: bool = true,
    };
}

pub fn rateLimit(comptime State: type, comptime opts: Options(State)) app_mod.Middleware(State) {
    const State_ = struct {
        var gpa: std.mem.Allocator = undefined;
        var mu: sync.Mutex = .{};
        var entries: ?std.StringHashMap(Entry) = null;
        var inited: std.atomic.Value(u8) = .init(0);

        fn ensureInit() void {
            if (inited.load(.acquire) == 2) return;
            if (inited.cmpxchgStrong(0, 1, .acq_rel, .monotonic) == null) {
                gpa = std.heap.smp_allocator;
                mu = sync.Mutex.init();
                entries = std.StringHashMap(Entry).init(gpa);
                inited.store(2, .release);
            } else {
                while (inited.load(.acquire) != 2) std.atomic.spinLoopHint();
            }
        }
    };

    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            State_.ensureInit();
            const key = opts.key_fn(c);
            const now = nowUnix();

            State_.mu.lock();
            const gop = State_.entries.?.getOrPut(key) catch {
                State_.mu.unlock();
                return next.run(c);
            };
            if (!gop.found_existing) {
                gop.key_ptr.* = State_.gpa.dupe(u8, key) catch {
                    State_.mu.unlock();
                    return next.run(c);
                };
                gop.value_ptr.* = .{ .window_start = now, .count = 0 };
            }
            const entry = gop.value_ptr;
            const window_secs_i: i64 = @intCast(opts.window_secs);
            if (now - entry.window_start >= window_secs_i) {
                entry.window_start = now;
                entry.count = 0;
            }
            entry.count += 1;
            const count = entry.count;
            const reset_in = window_secs_i - (now - entry.window_start);
            State_.mu.unlock();

            if (opts.emit_headers) {
                var buf: [32]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{d}", .{opts.max_requests})) |s| {
                    try c.header("x-ratelimit-limit", s);
                } else |_| {}
                const remaining: i64 = @as(i64, opts.max_requests) - @as(i64, count);
                if (std.fmt.bufPrint(&buf, "{d}", .{@max(remaining, 0)})) |s| {
                    try c.header("x-ratelimit-remaining", s);
                } else |_| {}
                if (std.fmt.bufPrint(&buf, "{d}", .{reset_in})) |s| {
                    try c.header("x-ratelimit-reset", s);
                } else |_| {}
            }

            if (count > opts.max_requests) {
                var buf: [32]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{d}", .{reset_in})) |s| {
                    c.header("retry-after", s) catch {};
                } else |_| {}
                return c.json(.{ .error_kind = "rate_limited" }, 429);
            }
            return next.run(c);
        }
    };
    return .{ .name = "rateLimit", .call = Impl.call };
}

extern "c" fn time(t: ?*i64) i64;
fn nowUnix() i64 {
    return time(null);
}
