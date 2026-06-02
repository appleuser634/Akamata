// One-line-per-request access logger. Two formats:
//   .combined → Apache combined log (single-line, easy to grep)
//   .json     → JSON Lines, fields stable for ingestion
//
// Reads request_id from `c.user_data` if the requestId middleware ran
// first; otherwise emits "-".

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const rid_mod = @import("requestid.zig");

const is_wasm = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

pub const Format = enum { combined, json };

pub fn accessLog(comptime State: type, comptime format: Format) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const t0 = nowNs();
            // Capture the requestId before the handler is allowed to clobber
            // c.user_data (e.g. the session mw will replace it).
            const rid_snapshot: ?[36]u8 = blk: {
                if (c.user_data) |p| {
                    const slot: *rid_mod.RequestIdSlot = @ptrCast(@alignCast(p));
                    break :blk slot.id;
                }
                break :blk null;
            };
            const err_result = next.run(c);
            const elapsed_ns = nowNs() - t0;
            const elapsed_us = @divTrunc(elapsed_ns, 1000);

            const rid: []const u8 = if (rid_snapshot) |s| trimZeros(&s) else "-";
            const ip = c.req.ip() orelse "-";
            const method_str = c.req.method();
            const path = c.req.path();
            const status_code = c.res.status_code;

            switch (format) {
                .combined => {
                    std.log.info("{s} {s} \"{s} {s}\" {d} {d}us req_id={s}", .{
                        ip,            "-",       method_str, path,
                        status_code,   elapsed_us, rid,
                    });
                },
                .json => {
                    // 1-line JSON, no allocator needed. We bufPrint directly
                    // and emit via std.log.info to keep formatting cheap.
                    var buf: [512]u8 = undefined;
                    if (std.fmt.bufPrint(
                        &buf,
                        "{{\"ts_unix_us\":{d},\"req_id\":\"{s}\",\"ip\":\"{s}\",\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"latency_us\":{d}}}",
                        .{ unixMicros(), rid, ip, method_str, path, status_code, elapsed_us },
                    )) |line| {
                        std.log.info("{s}", .{line});
                    } else |_| {}
                },
            }
            return err_result;
        }

        fn trimZeros(s: []const u8) []const u8 {
            var end: usize = s.len;
            while (end > 0 and s[end - 1] == 0) end -= 1;
            return s[0..end];
        }
    };
    return .{ .name = "accessLog", .call = Impl.call };
}

const Timespec = extern struct { tv_sec: c_long, tv_nsec: c_long };
extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
extern "akamata_env" fn akamata_unix_seconds() i64;

fn nowNs() i64 {
    if (is_wasm) {
        // Workers can't give us a monotonic clock; the JS host only exposes
        // wall-clock seconds. Use it (in nanoseconds) so the access log still
        // gets a usable latency figure on Workers.
        return akamata_unix_seconds() * std.time.ns_per_s;
    }
    const CLOCK_MONOTONIC: c_int = 6;
    var ts: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return (@as(i64, ts.tv_sec) * std.time.ns_per_s) + @as(i64, ts.tv_nsec);
}

fn unixMicros() i64 {
    if (is_wasm) return akamata_unix_seconds() * 1_000_000;
    const CLOCK_REALTIME: c_int = 0;
    var ts: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    _ = clock_gettime(CLOCK_REALTIME, &ts);
    return (@as(i64, ts.tv_sec) * 1_000_000) + @divTrunc(@as(i64, ts.tv_nsec), 1000);
}
