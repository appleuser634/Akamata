// Minimal in-process metrics. Lock-free atomic counters/histograms plus
// a Prometheus-style `/metrics` endpoint.
//
// What's exposed (all gauges/counters share the `akamata_` prefix):
//
//   akamata_requests_total                       counter
//   akamata_requests_in_flight                   gauge
//   akamata_requests_by_status{class="…"}        counter, label cardinality = 5
//   akamata_requests_by_method{method="…"}       counter, label cardinality = 8
//   akamata_request_latency_seconds_bucket{le=…} histogram (cumulative)
//   akamata_request_latency_seconds_count
//   akamata_request_latency_seconds_sum
//   akamata_process_resident_memory_bytes        gauge (sampled at scrape time)
//   akamata_process_start_time_seconds           gauge (set on first record())
//   akamata_process_uptime_seconds               gauge (derived at scrape time)
//
// Cardinality is fixed at compile time — there's no per-path label, which is
// intentional (path templates require a router-aware design that's tracked
// for a future iteration). Method labels are limited to the seven RFC 7231
// verbs + `OTHER`, so a misbehaving client can't blow up the series cardinality.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");

pub const Method = enum(u8) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    PATCH = 4,
    HEAD = 5,
    OPTIONS = 6,
    OTHER = 7,
};

fn methodFromString(s: []const u8) Method {
    if (std.mem.eql(u8, s, "GET")) return .GET;
    if (std.mem.eql(u8, s, "POST")) return .POST;
    if (std.mem.eql(u8, s, "PUT")) return .PUT;
    if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
    return .OTHER;
}

pub const Counters = struct {
    /// Total successful + failed requests served.
    requests_total: std.atomic.Value(u64) = .init(0),
    /// In-flight requests right now (incremented on entry, decremented on exit).
    requests_in_flight: std.atomic.Value(i64) = .init(0),
    /// Buckets: 1xx, 2xx, 3xx, 4xx, 5xx.
    by_status_class: [5]std.atomic.Value(u64) = .{ .init(0), .init(0), .init(0), .init(0), .init(0) },
    /// Per-method counts. Indexed by `Method` enum (8 values).
    by_method: [8]std.atomic.Value(u64) = .{ .init(0), .init(0), .init(0), .init(0), .init(0), .init(0), .init(0), .init(0) },
    /// Cumulative request latency in microseconds. Combined with
    /// `requests_total` this gives Prometheus a real `_sum` (so average
    /// latency = sum / count works).
    latency_us_total: std.atomic.Value(u64) = .init(0),
    /// Latency histogram (microseconds):
    /// <=100, <=500, <=1000, <=5000, <=10_000, <=50_000, <=100_000, >100_000
    latency_buckets: [8]std.atomic.Value(u64) = .{ .init(0), .init(0), .init(0), .init(0), .init(0), .init(0), .init(0), .init(0) },
    /// Unix seconds at which the first request landed. `0` until then.
    start_time_unix: std.atomic.Value(i64) = .init(0),

    pub fn record(self: *Counters, method: Method, status_code: u16, elapsed_us: u64) void {
        // Stamp the start time lazily on the first observation. CAS so
        // concurrent first-callers don't overwrite each other.
        _ = self.start_time_unix.cmpxchgStrong(0, unixSeconds(), .monotonic, .monotonic);
        _ = self.requests_total.fetchAdd(1, .monotonic);
        _ = self.latency_us_total.fetchAdd(elapsed_us, .monotonic);
        const cls: usize = switch (status_code / 100) {
            1 => 0,
            2 => 1,
            3 => 2,
            4 => 3,
            5 => 4,
            else => 4,
        };
        _ = self.by_status_class[cls].fetchAdd(1, .monotonic);
        _ = self.by_method[@intFromEnum(method)].fetchAdd(1, .monotonic);
        const bucket: usize = if (elapsed_us <= 100) 0
        else if (elapsed_us <= 500) 1
        else if (elapsed_us <= 1_000) 2
        else if (elapsed_us <= 5_000) 3
        else if (elapsed_us <= 10_000) 4
        else if (elapsed_us <= 50_000) 5
        else if (elapsed_us <= 100_000) 6
        else 7;
        _ = self.latency_buckets[bucket].fetchAdd(1, .monotonic);
    }
};

/// Cross-platform monotonic clock helper.
fn nanoMonotonic() i128 {
    if (builtin.os.tag == .windows) return 0;
    const Lib = struct {
        const Timespec = extern struct { tv_sec: c_long, tv_nsec: c_long };
        extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
    };
    const CLOCK_MONOTONIC: c_int = 6;
    var ts: Lib.Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = Lib.clock_gettime(CLOCK_MONOTONIC, &ts);
    return (@as(i128, ts.tv_sec) * std.time.ns_per_s) + @as(i128, ts.tv_nsec);
}

fn unixSeconds() i64 {
    if (builtin.os.tag == .windows) return 0;
    const Lib = struct {
        const Timespec = extern struct { tv_sec: c_long, tv_nsec: c_long };
        extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
    };
    const CLOCK_REALTIME: c_int = 0;
    var ts: Lib.Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = Lib.clock_gettime(CLOCK_REALTIME, &ts);
    return @intCast(ts.tv_sec);
}

/// Best-effort RSS in bytes for the current process. Returns 0 if unavailable.
/// macOS reports max_resident in `struct rusage.ru_maxrss` in bytes;
/// Linux reports the same field in KiB. Other platforms return 0.
fn residentMemoryBytes() u64 {
    if (builtin.os.tag == .wasi or builtin.cpu.arch == .wasm32) return 0;
    const Rusage = extern struct {
        ru_utime: extern struct { sec: c_long, usec: c_long },
        ru_stime: extern struct { sec: c_long, usec: c_long },
        ru_maxrss: c_long,
        // … remaining fields don't matter; getrusage writes them but we ignore.
        ru_ixrss: c_long = 0,
        ru_idrss: c_long = 0,
        ru_isrss: c_long = 0,
        ru_minflt: c_long = 0,
        ru_majflt: c_long = 0,
        ru_nswap: c_long = 0,
        ru_inblock: c_long = 0,
        ru_oublock: c_long = 0,
        ru_msgsnd: c_long = 0,
        ru_msgrcv: c_long = 0,
        ru_nsignals: c_long = 0,
        ru_nvcsw: c_long = 0,
        ru_nivcsw: c_long = 0,
    };
    const RUSAGE_SELF: c_int = 0;
    const Lib = struct {
        extern "c" fn getrusage(who: c_int, usage: *Rusage) c_int;
    };
    var u: Rusage = std.mem.zeroes(Rusage);
    if (Lib.getrusage(RUSAGE_SELF, &u) != 0) return 0;
    const raw: u64 = if (u.ru_maxrss <= 0) 0 else @intCast(u.ru_maxrss);
    // On Linux ru_maxrss is KiB; on macOS / BSD it is bytes.
    return if (builtin.os.tag == .linux) raw * 1024 else raw;
}

/// Middleware factory. Pass the same `*Counters` to both this and the
/// optional `metricsHandler` so the data they share lines up.
pub fn metrics(comptime State: type, c_ptr: *Counters) app_mod.Middleware(State) {
    const Impl = struct {
        var counters_ref: *Counters = undefined;
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            _ = counters_ref.requests_in_flight.fetchAdd(1, .monotonic);
            defer _ = counters_ref.requests_in_flight.fetchSub(1, .monotonic);
            const t0 = nanoMonotonic();
            const result = next.run(c);
            const elapsed_us: u64 = @intCast(@divTrunc(nanoMonotonic() - t0, std.time.ns_per_us));
            const method = methodFromString(c.req.method());
            counters_ref.record(method, c.res.status_code, elapsed_us);
            return result;
        }
    };
    Impl.counters_ref = c_ptr;
    return .{ .name = "metrics", .call = Impl.call };
}

/// `GET /metrics` handler that emits the counters in Prometheus text format.
pub fn metricsHandler(comptime State: type, c_ptr: *Counters) app_mod.Handler(State) {
    const Impl = struct {
        var counters_ref: *Counters = undefined;
        fn call(c: *app_mod.App(State).Ctx) anyerror!void {
            const total = counters_ref.requests_total.load(.monotonic);
            const in_flight = counters_ref.requests_in_flight.load(.monotonic);
            const lat_total_us = counters_ref.latency_us_total.load(.monotonic);
            const start_t = counters_ref.start_time_unix.load(.monotonic);
            const now_t = unixSeconds();
            const rss = residentMemoryBytes();

            var buf: std.ArrayList(u8) = .empty;
            const w = struct {
                fn append(arena: std.mem.Allocator, b: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
                    const s = try std.fmt.allocPrint(arena, fmt, args);
                    try b.appendSlice(arena, s);
                }
            };

            // === request counters ===
            try w.append(c.arena, &buf,
                "# HELP akamata_requests_total Total HTTP requests served.\n" ++
                "# TYPE akamata_requests_total counter\n" ++
                "akamata_requests_total {d}\n", .{total});
            try w.append(c.arena, &buf,
                "# HELP akamata_requests_in_flight Requests currently being processed.\n" ++
                "# TYPE akamata_requests_in_flight gauge\n" ++
                "akamata_requests_in_flight {d}\n", .{in_flight});

            // by status class
            try w.append(c.arena, &buf,
                "# HELP akamata_requests_by_status Requests broken down by HTTP status class.\n" ++
                "# TYPE akamata_requests_by_status counter\n", .{});
            const classes = [_][]const u8{ "1xx", "2xx", "3xx", "4xx", "5xx" };
            for (classes, 0..) |name, i| {
                const v = counters_ref.by_status_class[i].load(.monotonic);
                try w.append(c.arena, &buf, "akamata_requests_by_status{{class=\"{s}\"}} {d}\n", .{ name, v });
            }

            // by method (fixed cardinality)
            try w.append(c.arena, &buf,
                "# HELP akamata_requests_by_method Requests broken down by HTTP method.\n" ++
                "# TYPE akamata_requests_by_method counter\n", .{});
            const method_names = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "OTHER" };
            for (method_names, 0..) |name, i| {
                const v = counters_ref.by_method[i].load(.monotonic);
                try w.append(c.arena, &buf, "akamata_requests_by_method{{method=\"{s}\"}} {d}\n", .{ name, v });
            }

            // === latency histogram ===
            try w.append(c.arena, &buf,
                "# HELP akamata_request_latency_seconds Request latency in seconds.\n" ++
                "# TYPE akamata_request_latency_seconds histogram\n", .{});
            const bucket_le = [_][]const u8{ "0.0001", "0.0005", "0.001", "0.005", "0.01", "0.05", "0.1", "+Inf" };
            var cumulative: u64 = 0;
            for (bucket_le, 0..) |label, i| {
                cumulative += counters_ref.latency_buckets[i].load(.monotonic);
                try w.append(c.arena, &buf, "akamata_request_latency_seconds_bucket{{le=\"{s}\"}} {d}\n", .{ label, cumulative });
            }
            try w.append(c.arena, &buf, "akamata_request_latency_seconds_count {d}\n", .{cumulative});
            // _sum is in seconds — divide microseconds by 1e6, but emit
            // as decimal so we don't lose precision through integer math.
            const sum_sec_int = lat_total_us / 1_000_000;
            const sum_sec_frac = lat_total_us % 1_000_000;
            try w.append(c.arena, &buf, "akamata_request_latency_seconds_sum {d}.{d:0>6}\n", .{ sum_sec_int, sum_sec_frac });

            // === process info ===
            try w.append(c.arena, &buf,
                "# HELP akamata_process_resident_memory_bytes Resident memory (max-RSS).\n" ++
                "# TYPE akamata_process_resident_memory_bytes gauge\n" ++
                "akamata_process_resident_memory_bytes {d}\n", .{rss});
            if (start_t > 0) {
                try w.append(c.arena, &buf,
                    "# HELP akamata_process_start_time_seconds Unix time the metrics middleware first observed a request.\n" ++
                    "# TYPE akamata_process_start_time_seconds gauge\n" ++
                    "akamata_process_start_time_seconds {d}\n", .{start_t});
                try w.append(c.arena, &buf,
                    "# HELP akamata_process_uptime_seconds Seconds since the first observed request.\n" ++
                    "# TYPE akamata_process_uptime_seconds gauge\n" ++
                    "akamata_process_uptime_seconds {d}\n", .{now_t - start_t});
            }

            try c.header("content-type", "text/plain; version=0.0.4; charset=utf-8");
            c.status(200);
            try c.body(buf.items);
        }
    };
    Impl.counters_ref = c_ptr;
    return Impl.call;
}

// === Tests ===

const testing = std.testing;

test "methodFromString covers the known verbs" {
    try testing.expectEqual(Method.GET, methodFromString("GET"));
    try testing.expectEqual(Method.POST, methodFromString("POST"));
    try testing.expectEqual(Method.DELETE, methodFromString("DELETE"));
    try testing.expectEqual(Method.OPTIONS, methodFromString("OPTIONS"));
    try testing.expectEqual(Method.OTHER, methodFromString("GIBBERISH"));
}

test "Counters.record stamps start_time on the first call only" {
    var c: Counters = .{};
    try testing.expectEqual(@as(i64, 0), c.start_time_unix.load(.monotonic));
    c.record(.GET, 200, 50);
    const t1 = c.start_time_unix.load(.monotonic);
    try testing.expect(t1 > 0);
    c.record(.POST, 404, 150);
    const t2 = c.start_time_unix.load(.monotonic);
    try testing.expectEqual(t1, t2); // doesn't change on subsequent calls
    try testing.expectEqual(@as(u64, 2), c.requests_total.load(.monotonic));
    try testing.expectEqual(@as(u64, 200), c.latency_us_total.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), c.by_method[@intFromEnum(Method.GET)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), c.by_status_class[1].load(.monotonic)); // 2xx
    try testing.expectEqual(@as(u64, 1), c.by_status_class[3].load(.monotonic)); // 4xx
}
