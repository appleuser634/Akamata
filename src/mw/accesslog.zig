// One-line-per-request access logger. Two formats:
//   .combined → Apache combined log (single-line, easy to grep)
//   .json     → JSON Lines, fields stable for ingestion
//
// Reads request_id from `c.user_data` if the requestId middleware ran
// first; otherwise emits "-".

const std = @import("std");
const app_mod = @import("../app.zig");
const clock = @import("../observability/clock.zig");

pub const Format = enum { combined, json };
pub const Options = struct { format: Format = .json, include_raw_path: bool = false };

pub fn accessLog(comptime State: type, comptime format: Format) app_mod.Middleware(State) {
    return accessLogWithOptions(State, .{ .format = format, .include_raw_path = true });
}

pub fn accessLogWithOptions(comptime State: type, comptime options: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const t0 = clock.monotonicNs();
            const err_result = next.run(c);
            const elapsed_ns = clock.elapsedNs(t0);
            const elapsed_us = @divTrunc(elapsed_ns, 1000);

            const rid = c.requestId() orelse "-";
            const ip = c.req.ip() orelse "-";
            const method_str = c.req.method();
            const path = c.req.path();
            const status_code = c.res.status_code;

            const route = c.routePattern() orelse "-";
            switch (options.format) {
                .combined => {
                    std.log.info("{s} {s} \"{s} {s}\" {d} {d}us req_id={s}", .{
                        ip,          "-",        method_str, path,
                        status_code, elapsed_us, rid,
                    });
                },
                .json => {
                    // 1-line JSON, no allocator needed. We bufPrint directly
                    // and emit via std.log.info to keep formatting cheap.
                    var buf: [1024]u8 = undefined;
                    const raw_path = if (options.include_raw_path) path else "-";
                    if (std.fmt.bufPrint(
                        &buf,
                        "{{\"ts_unix_us\":{d},\"request_id\":\"{s}\",\"method\":\"{s}\",\"path\":\"{s}\",\"route\":\"{s}\",\"status\":{d},\"duration_ms\":{d}.{d:0>3},\"db\":{{\"queries\":{d},\"execs\":{d},\"errors\":{d},\"duration_ms\":{d}.{d:0>3}}},\"outbound_http\":{{\"requests\":{d},\"duration_ms\":{d}.{d:0>3}}},\"storage\":{{\"operations\":{d},\"duration_ms\":{d}.{d:0>3}}}}}",
                        .{ clock.unixMicros(), rid, method_str, raw_path, route, status_code, elapsed_us / 1000, elapsed_us % 1000, c.trace.db_queries, c.trace.db_execs, c.trace.db_errors, c.trace.db_ns / std.time.ns_per_ms, (c.trace.db_ns % std.time.ns_per_ms) / std.time.ns_per_us, c.trace.outbound_http_requests, c.trace.outbound_http_ns / std.time.ns_per_ms, (c.trace.outbound_http_ns % std.time.ns_per_ms) / std.time.ns_per_us, c.trace.storage_operations, c.trace.storage_ns / std.time.ns_per_ms, (c.trace.storage_ns % std.time.ns_per_ms) / std.time.ns_per_us },
                    )) |line| {
                        std.log.info("{s}", .{line});
                    } else |_| {}
                },
            }
            return err_result;
        }
    };
    return .{ .name = "accessLog", .call = Impl.call };
}
