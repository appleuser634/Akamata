//! Portable crypto helpers; Workers externs remain behind `random.fill`.
const std = @import("std");
const random = @import("random.zig");

pub fn randomBytes(out: []u8) void {
    random.fill(out);
}

pub fn randomHex(allocator: std.mem.Allocator, byte_count: usize) ![]u8 {
    const raw = try allocator.alloc(u8, byte_count);
    defer allocator.free(raw);
    random.fill(raw);
    const output_len = std.math.mul(usize, byte_count, 2) catch return error.OutOfMemory;
    const out = try allocator.alloc(u8, output_len);
    for (raw, 0..) |byte, i| {
        const alphabet = "0123456789abcdef";
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

test "randomHex accepts zero, fixed, and runtime lengths" {
    const lengths = [_]usize{ 0, 1, 32, 7 };
    var runtime_index: usize = 0;
    while (runtime_index < lengths.len) : (runtime_index += 1) {
        const byte_count = lengths[runtime_index];
        const value = try randomHex(std.testing.allocator, byte_count);
        defer std.testing.allocator.free(value);
        try std.testing.expectEqual(byte_count * 2, value.len);
        for (value) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    }
}

pub fn sha256(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    return std.fmt.bytesToHex(sha256(bytes), .lower);
}

pub fn timingSafeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var different: u8 = 0;
    for (a, b) |x, y| different |= x ^ y;
    return different == 0;
}

/// Compare serialized origins (`scheme://authority`), rejecting paths,
/// credentials and malformed values. Default ports remain explicit.
pub fn sameOrigin(a: []const u8, b: []const u8) bool {
    const ap = originParts(a) orelse return false;
    const bp = originParts(b) orelse return false;
    return std.ascii.eqlIgnoreCase(ap.scheme, bp.scheme) and std.ascii.eqlIgnoreCase(ap.authority, bp.authority);
}

const Origin = struct { scheme: []const u8, authority: []const u8 };
fn originParts(value: []const u8) ?Origin {
    const marker = std.mem.indexOf(u8, value, "://") orelse return null;
    if (marker == 0) return null;
    const authority = value[marker + 3 ..];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "/?#@") != null) return null;
    return .{ .scheme = value[0..marker], .authority = authority };
}

test "portable crypto helpers" {
    try std.testing.expect(timingSafeEqual("abc", "abc"));
    try std.testing.expect(!timingSafeEqual("abc", "abd"));
    try std.testing.expect(sameOrigin("https://example.com", "HTTPS://EXAMPLE.COM"));
    try std.testing.expect(!sameOrigin("https://example.com", "https://evil.example"));
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &sha256Hex("abc"));
}
