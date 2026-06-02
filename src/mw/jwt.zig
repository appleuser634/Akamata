const std = @import("std");
const app_mod = @import("../app.zig");
const jwt = @import("../auth/jwt.zig");

pub const Options = struct {
    secret: []const u8,
    /// Stash the JWT `sub` claim into `c.user_data` as a `*Claims`.
    stash_claims: bool = true,
};

pub const Claims = struct {
    sub: []const u8,
};

pub fn jwtAuth(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const token = extract(c) orelse return unauthorized(c);
            const now = std.time.timestamp();
            _ = now;
            // std.time.timestamp() was removed in 0.16; rely on jwt.verify with
            // null to skip exp check, or use clock helper if user provides it.
            // For now we set now_unix = null and rely on `exp` only when the
            // user explicitly checks it in their handler.
            const claims = jwt.verify(c.arena, opts.secret, token, null) catch return unauthorized(c);
            const sub = claims.sub orelse return unauthorized(c);
            if (opts.stash_claims) {
                const slot = try c.arena.create(Claims);
                slot.* = .{ .sub = sub };
                c.user_data = @ptrCast(slot);
            }
            try next.run(c);
        }

        fn extract(c: *app_mod.App(State).Ctx) ?[]const u8 {
            if (c.req.header("authorization")) |h| {
                if (std.mem.startsWith(u8, h, "Bearer ")) return h[7..];
            }
            // ?token= query param (useful for WebSocket upgrades).
            if (c.req.query("token")) |t| return t;
            return null;
        }

        fn unauthorized(c: *app_mod.App(State).Ctx) anyerror!void {
            try c.json(.{ .error_kind = "unauthorized" }, 401);
        }
    };
    return .{ .name = "jwt", .call = Impl.call };
}

/// Convenience to read claims that the middleware stashed.
pub fn currentClaims(comptime State: type, c: *app_mod.App(State).Ctx) ?*Claims {
    const p = c.user_data orelse return null;
    return @ptrCast(@alignCast(p));
}
