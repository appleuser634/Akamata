//! Shared wall and monotonic clocks. Durations must only use `monotonicNs`.
const std = @import("std");
const builtin = @import("builtin");

const is_workers = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;
const Timespec = extern struct { tv_sec: c_long, tv_nsec: c_long };
extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
extern "akamata_env" fn akamata_monotonic_ns() i64;
extern "akamata_env" fn akamata_unix_micros() i64;

pub fn monotonicNs() u64 {
    if (is_workers) return @intCast(@max(akamata_monotonic_ns(), 0));
    if (builtin.os.tag == .windows) return 0;
    const clock_id: c_int = if (builtin.os.tag == .linux) 1 else 6;
    var ts: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    if (clock_gettime(clock_id, &ts) != 0) return 0;
    return @intCast((@as(i128, ts.tv_sec) * std.time.ns_per_s) + ts.tv_nsec);
}

pub fn unixMicros() i64 {
    if (is_workers) return akamata_unix_micros();
    if (builtin.os.tag == .windows) return 0;
    var ts: Timespec = .{ .tv_sec = 0, .tv_nsec = 0 };
    if (clock_gettime(0, &ts) != 0) return 0;
    return (@as(i64, ts.tv_sec) * std.time.us_per_s) + @divTrunc(ts.tv_nsec, std.time.ns_per_us);
}

/// Wall-clock Unix time for expiry/validity checks. Never use this for
/// durations; wall clocks may move backwards or jump forwards.
pub fn unixSeconds() i64 {
    return @divFloor(unixMicros(), std.time.us_per_s);
}

pub fn elapsedNs(start_ns: u64) u64 {
    const now = monotonicNs();
    return if (now >= start_ns) now - start_ns else 0;
}
