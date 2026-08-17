const std = @import("std");
const app_mod = @import("../app.zig");
const jwt = @import("../auth/jwt.zig");
const clock = @import("../observability/clock.zig");

pub const Options = struct {
    secret: []const u8,
    /// Stash the JWT `sub` claim into `c.user_data` as a `*Claims`.
    stash_claims: bool = true,
    /// Authentication tokens without an expiry are rejected by default.
    require_exp: bool = true,
    leeway_seconds: u32 = 0,
    reject_future_iat: bool = false,
    /// Query-string bearer tokens leak through URLs and logs. Disabled by
    /// default; enable only for a constrained WebSocket handshake flow.
    allow_query_token: bool = false,
    now_fn: *const fn () i64 = clock.unixSeconds,
};

pub const Claims = struct {
    sub: []const u8,
};

pub fn jwtAuth(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    if (opts.secret.len < 32) @compileError("JWT HS256 secret must be at least 32 bytes");
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const token = extract(c) orelse return unauthorized(c);
            const claims = jwt.verifyWithOptions(c.arena, opts.secret, token, .{
                .now_unix = opts.now_fn(),
                .require_exp = opts.require_exp,
                .leeway_seconds = opts.leeway_seconds,
                .reject_future_iat = opts.reject_future_iat,
            }) catch return unauthorized(c);
            const sub = claims.sub orelse return unauthorized(c);
            if (opts.stash_claims) {
                const slot = try c.arena.create(Claims);
                slot.* = .{ .sub = sub };
                c.auth_data = @ptrCast(slot);
            }
            try next.run(c);
        }

        fn extract(c: *app_mod.App(State).Ctx) ?[]const u8 {
            if (c.req.header("authorization")) |h| {
                if (std.mem.startsWith(u8, h, "Bearer ")) return h[7..];
            }
            // ?token= query param (useful for WebSocket upgrades).
            if (opts.allow_query_token) if (c.req.query("token")) |t| return t;
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
    const p = c.auth_data orelse return null;
    return @ptrCast(@alignCast(p));
}
