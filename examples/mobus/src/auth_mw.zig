const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const clock = @import("clock.zig");

const Ctx = am.Context(App);

/// JWT middleware for mobus: enforces `Authorization: Bearer <jwt>` on every
/// API call except a small allowlist of public routes. The verified `sub`
/// claim is stashed in `c.user_data` as a `am.mw.JwtClaims*`.
pub fn jwtAuth() am.Middleware(App) {
    return .{ .name = "mobusJwt", .call = call };
}

fn call(c: *Ctx, next: am.Next(App)) anyerror!void {
    const path = c.req.path();
    if (std.mem.startsWith(u8, path, "/api/public/") or
        std.mem.eql(u8, path, "/api/auth/register") or
        std.mem.eql(u8, path, "/api/auth/login") or
        std.mem.eql(u8, path, "/api/auth/login-id-available"))
    {
        return next.run(c);
    }

    const token = extractToken(c) orelse {
        return c.json(.{ .error_kind = "unauthorized", .message = "missing bearer token" }, 401);
    };
    // Real wall clock; rejects expired tokens (security-relevant).
    const now = clock.unixSeconds();
    const claims = am.auth.jwt.verify(c.arena, c.state().cfg.jwt_secret, token, now) catch |e| {
        const kind: []const u8 = switch (e) {
            am.auth.jwt.JwtError.Expired => "token_expired",
            am.auth.jwt.JwtError.InvalidAlgorithm => "alg_not_supported",
            am.auth.jwt.JwtError.InvalidSignature => "bad_signature",
            else => "invalid_token",
        };
        return c.json(.{ .error_kind = "unauthorized", .reason = kind }, 401);
    };
    const sub = claims.sub orelse {
        return c.json(.{ .error_kind = "unauthorized", .message = "no sub claim" }, 401);
    };
    const slot = try c.arena.create(am.mw.JwtClaims);
    slot.* = .{ .sub = sub };
    c.user_data = @ptrCast(slot);
    return next.run(c);
}

fn extractToken(c: *Ctx) ?[]const u8 {
    if (c.req.header("authorization")) |h| {
        if (std.mem.startsWith(u8, h, "Bearer ")) return h[7..];
    }
    return c.req.query("token");
}

/// Returns the authenticated user_id. If unauthenticated, writes 401 and
/// returns error.Unauthorized — handlers should `try requireUser(c)`.
pub fn requireUser(c: *Ctx) ![]const u8 {
    const claims = am.mw.currentJwtClaims(App, c) orelse {
        try c.json(.{ .error_kind = "unauthorized" }, 401);
        return error.Unauthorized;
    };
    return claims.sub;
}
