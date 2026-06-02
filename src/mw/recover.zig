const std = @import("std");
const app_mod = @import("../app.zig");

pub fn recover(comptime State: type) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            next.run(c) catch |err| {
                std.log.err("uncaught handler error: {t}", .{err});
                c.res.body.clearRetainingCapacity();
                c.res.headers.clearRetainingCapacity();
                c.res.setStatus(500);
                c.res.json(.{ .error_kind = "internal", .message = "internal server error" }) catch {};
            };
        }
    };
    return .{ .name = "recover", .call = Impl.call };
}
