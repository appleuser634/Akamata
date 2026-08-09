const std = @import("std");
const app_mod = @import("../app.zig");

pub const Options = struct {
    enabled: bool = false,
    include_named_spans: bool = true,
};

/// Opt-in diagnostic response timing. Span names are sanitized and capped;
/// SQL, URLs and other attributes are never emitted.
pub fn serverTiming(comptime State: type, comptime options: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const result = next.run(c);
            if (options.enabled) {
                var buf: [1024]u8 = undefined;
                var len: usize = 0;
                appendMetric(&buf, &len, "db", c.trace.db_ns);
                appendMetric(&buf, &len, "http", c.trace.outbound_http_ns);
                appendMetric(&buf, &len, "storage", c.trace.storage_ns);
                if (options.include_named_spans) {
                    for (c.trace.spans[0..c.trace.span_count]) |span| {
                        if (!safeName(span.name) or span.duration_ns == 0) continue;
                        appendMetric(&buf, &len, span.name, span.duration_ns);
                    }
                }
                if (len > 0) try c.header("server-timing", try c.arena.dupe(u8, buf[0..len]));
            }
            return result;
        }
        fn appendMetric(buf: []u8, len: *usize, name: []const u8, ns: u64) void {
            if (ns == 0) return;
            const prefix = if (len.* > 0) ", " else "";
            const value = std.fmt.bufPrint(buf[len.*..], "{s}{s};dur={d}.{d:0>3}", .{ prefix, name, ns / std.time.ns_per_ms, (ns % std.time.ns_per_ms) / std.time.ns_per_us }) catch return;
            len.* += value.len;
        }
        fn safeName(name: []const u8) bool {
            if (name.len == 0 or name.len > 48) return false;
            for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return false;
            return true;
        }
    };
    return .{ .name = "serverTiming", .call = Impl.call };
}
