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
