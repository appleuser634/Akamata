const std = @import("std");
const app_mod = @import("../app.zig");

pub const Options = struct {
    token: []const u8,
    realm: []const u8 = "Restricted",
};

pub fn bearerAuth(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const h = c.req.header("authorization") orelse return unauthorized(c);
            if (!std.mem.startsWith(u8, h, "Bearer ")) return unauthorized(c);
            const got = h[7..];
            if (!ctEqual(got, opts.token)) return unauthorized(c);
            try next.run(c);
        }
        fn unauthorized(c: *app_mod.App(State).Ctx) anyerror!void {
            try c.header("www-authenticate", "Bearer realm=\"" ++ opts.realm ++ "\"");
            try c.json(.{ .error_kind = "unauthorized" }, 401);
        }
    };
    return .{ .name = "bearerAuth", .call = Impl.call };
}

fn ctEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}
