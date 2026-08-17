// Re-run inline tests from src/auth/jwt.zig through the public API.
const std = @import("std");
const am = @import("akamata");

test "JWT HS256 sign and verify round-trip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Payload = struct { sub: []const u8, exp: i64 };
    const tok = try am.auth.jwt.sign(arena, "k", Payload{ .sub = "u", .exp = 9_999_999_999 });
    const c = try am.auth.jwt.verify(arena, "k", tok, 1_000_000_000);
    try std.testing.expectEqualStrings("u", c.sub.?);
}

test "JWT rejects wrong secret" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Payload = struct { sub: []const u8, exp: i64 };
    const tok = try am.auth.jwt.sign(arena, "k1", Payload{ .sub = "u", .exp = 9_999_999_999 });
    try std.testing.expectError(am.auth.jwt.JwtError.InvalidSignature, am.auth.jwt.verify(arena, "k2", tok, null));
}

const JwtState = struct {};
fn jwtOk(c: *am.Context(JwtState)) !void {
    try c.text("ok");
}
fn fixedNow() i64 {
    return 1_000;
}

fn dispatchJwt(token: []const u8, comptime require_exp: bool) !u16 {
    var app = am.App(JwtState).init(std.testing.allocator, .{});
    defer app.deinit();
    _ = try app.useAll(am.mw.jwt(JwtState, .{
        .secret = "01234567890123456789012345678901",
        .require_exp = require_exp,
        .now_fn = fixedNow,
    }));
    _ = try app.get("/", jwtOk);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const authorization = try std.fmt.allocPrint(arena_state.allocator(), "Bearer {s}", .{token});
    var req: am.Request = .{ .method = .GET, .raw_method = "GET", .path = "/", .query = "", .version = "HTTP/1.1", .headers = &.{.{ .name = "authorization", .value = authorization }}, .body = "", .keep_alive = false };
    var res = am.Response.init(arena_state.allocator());
    try app.dispatchWithPeer(arena_state.allocator(), &req, &res, null, null, null);
    return res.status_code;
}

test "JWT middleware enforces exp and nbf with injected clock" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = "01234567890123456789012345678901";
    const expired = try am.auth.jwt.sign(arena, secret, .{ .sub = "u", .exp = 1000 });
    try std.testing.expectEqual(@as(u16, 401), try dispatchJwt(expired, true));
    const future = try am.auth.jwt.sign(arena, secret, .{ .sub = "u", .exp = 2000, .nbf = 1001 });
    try std.testing.expectEqual(@as(u16, 401), try dispatchJwt(future, true));
    const valid = try am.auth.jwt.sign(arena, secret, .{ .sub = "u", .exp = 2000, .nbf = 999 });
    try std.testing.expectEqual(@as(u16, 200), try dispatchJwt(valid, true));
    const missing = try am.auth.jwt.sign(arena, secret, .{ .sub = "u" });
    try std.testing.expectEqual(@as(u16, 401), try dispatchJwt(missing, true));
    try std.testing.expectEqual(@as(u16, 200), try dispatchJwt(missing, false));
}
