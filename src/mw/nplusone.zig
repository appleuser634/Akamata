const std = @import("std");
const app_mod = @import("../app.zig");

pub const Options = struct {
    threshold: u32 = 20,
    response_header: bool = false,
};

/// Development diagnostic for query-heavy request paths. It consumes the
/// existing request trace, so it adds no query interception or allocations.
pub fn nPlusOne(comptime State: type, comptime options: Options) app_mod.Middleware(State) {
    if (options.threshold == 0) @compileError("nPlusOne threshold must be greater than zero");
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const result = next.run(c);
            const operations = c.trace.db_queries +| c.trace.db_execs;
            if (operations > options.threshold) {
                std.log.warn("possible N+1 query pattern on {s}: {d} DB operations (threshold {d})", .{ c.routePattern() orelse c.req.path(), operations, options.threshold });
                if (options.response_header) try c.header("x-akamata-db-queries", try std.fmt.allocPrint(c.arena, "{d}", .{operations}));
            }
            return result;
        }
    };
    return .{ .name = "nPlusOne", .call = Impl.call };
}

test "nPlusOne middleware has a stable inspection name" {
    const State = struct {};
    const middleware = nPlusOne(State, .{ .threshold = 3 });
    try std.testing.expectEqualStrings("nPlusOne", middleware.name);
}
