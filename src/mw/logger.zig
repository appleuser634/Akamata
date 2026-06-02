const std = @import("std");
const app_mod = @import("../app.zig");

pub fn logger(comptime State: type) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const m = c.req.method();
            const p = c.req.path();
            next.run(c) catch |err| {
                std.log.err("{s} {s} -> error {t}", .{ m, p, err });
                return err;
            };
            std.log.info("{s} {s} -> {d}", .{ m, p, c.res.status_code });
        }
    };
    return .{ .name = "logger", .call = Impl.call };
}
