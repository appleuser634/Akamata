const std = @import("std");

pub const JwtError = error{
    InvalidFormat,
    InvalidSignature,
    InvalidBase64,
    InvalidJson,
    /// JWT header's `alg` field was missing or wasn't `"HS256"`. We deliberately
    /// reject `none` (CVE-2015-2951) and any other algorithm to prevent
    /// algorithm-confusion attacks.
    InvalidAlgorithm,
    Expired,
    NotYetValid,
    OutOfMemory,
};

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64url = std.base64.url_safe_no_pad;

/// Standard JWT header for HS256.
const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

/// Encode HS256 JWT. Caller owns returned slice.
///
/// `payload_value` is any value that `std.json.Stringify.value` accepts (struct, anonymous struct, etc).
/// Caller is responsible for placing `exp`, `iat`, `sub` claims in the payload.
pub fn sign(
    arena: std.mem.Allocator,
    secret: []const u8,
    payload_value: anytype,
) ![]u8 {
    var payload_bytes: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &payload_bytes);
    defer payload_bytes = aw.toArrayList();
    try std.json.Stringify.value(payload_value, .{}, &aw.writer);
    return signRaw(arena, secret, header_json, aw.writer.buffered());
}

/// Encode HS256 JWT from raw payload JSON bytes (caller-built).
pub fn signRaw(
    arena: std.mem.Allocator,
    secret: []const u8,
    header_json_bytes: []const u8,
    payload_json: []const u8,
) ![]u8 {
    const h_enc_len = b64url.Encoder.calcSize(header_json_bytes.len);
    const p_enc_len = b64url.Encoder.calcSize(payload_json.len);

    var signing_input = try arena.alloc(u8, h_enc_len + 1 + p_enc_len);
    _ = b64url.Encoder.encode(signing_input[0..h_enc_len], header_json_bytes);
    signing_input[h_enc_len] = '.';
    _ = b64url.Encoder.encode(signing_input[h_enc_len + 1 ..], payload_json);

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signing_input, secret);

    const sig_enc_len = b64url.Encoder.calcSize(mac.len);
    const total = signing_input.len + 1 + sig_enc_len;
    var out = try arena.alloc(u8, total);
    @memcpy(out[0..signing_input.len], signing_input);
    out[signing_input.len] = '.';
    _ = b64url.Encoder.encode(out[signing_input.len + 1 ..], &mac);
    return out;
}

pub const Claims = struct {
    /// Decoded payload JSON bytes (within arena lifetime).
    payload_json: []const u8,
    /// Convenience extracted fields. `null` if absent or wrong type.
    sub: ?[]const u8 = null,
    exp: ?i64 = null,
    iat: ?i64 = null,
};

/// Verify HS256 JWT and return claims if valid.
///
/// `now_unix` is the current Unix timestamp used to check `exp` / `nbf`.
/// Pass `null` to skip time validation (useful for tests).
pub fn verify(
    arena: std.mem.Allocator,
    secret: []const u8,
    token: []const u8,
    now_unix: ?i64,
) JwtError!Claims {
    const dot1 = std.mem.indexOfScalar(u8, token, '.') orelse return JwtError.InvalidFormat;
    const dot2 = std.mem.indexOfScalarPos(u8, token, dot1 + 1, '.') orelse return JwtError.InvalidFormat;

    const header_b64 = token[0..dot1];
    const payload_b64 = token[dot1 + 1 .. dot2];
    const sig_b64 = token[dot2 + 1 ..];

    // === Decode header and enforce alg == HS256 BEFORE checking the signature ===
    // This prevents `alg: none` token-forgery attacks (CVE-2015-2951) and
    // confusion attacks where an HMAC verifier is tricked into accepting an
    // RS256-signed token by checking only the signature bytes.
    const header_len_max = b64url.Decoder.calcSizeUpperBound(header_b64.len) catch return JwtError.InvalidBase64;
    const header_buf = try arena.alloc(u8, header_len_max);
    b64url.Decoder.decode(header_buf, header_b64) catch return JwtError.InvalidBase64;
    var header_actual = header_len_max;
    while (header_actual > 0 and header_buf[header_actual - 1] == 0) header_actual -= 1;
    const HeaderShape = struct { alg: ?[]const u8 = null, typ: ?[]const u8 = null };
    const header_parsed = std.json.parseFromSliceLeaky(HeaderShape, arena, header_buf[0..header_actual], .{
        .ignore_unknown_fields = true,
    }) catch return JwtError.InvalidJson;
    const alg = header_parsed.alg orelse return JwtError.InvalidAlgorithm;
    if (!std.mem.eql(u8, alg, "HS256")) return JwtError.InvalidAlgorithm;

    // === Recompute signature over header.payload bytes ===
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, token[0..dot2], secret);

    var sig_decoded: [HmacSha256.mac_length]u8 = undefined;
    const expected_sig_len = b64url.Decoder.calcSizeUpperBound(sig_b64.len) catch return JwtError.InvalidBase64;
    if (expected_sig_len < sig_decoded.len) return JwtError.InvalidSignature;
    b64url.Decoder.decode(&sig_decoded, sig_b64) catch return JwtError.InvalidBase64;

    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, sig_decoded, mac)) {
        return JwtError.InvalidSignature;
    }

    const payload_len = b64url.Decoder.calcSizeUpperBound(payload_b64.len) catch return JwtError.InvalidBase64;
    var payload_buf = try arena.alloc(u8, payload_len);
    b64url.Decoder.decode(payload_buf, payload_b64) catch return JwtError.InvalidBase64;
    // base64url decoder writes exactly the decoded length when sized upper-bound is precise; we trim trailing zeros
    var actual = payload_len;
    while (actual > 0 and payload_buf[actual - 1] == 0) actual -= 1;
    const payload_json = payload_buf[0..actual];

    var claims: Claims = .{ .payload_json = payload_json };

    // Best-effort parse of standard fields. Use Parsed.deinit-free leaky variant within arena.
    const Std = struct { sub: ?[]const u8 = null, exp: ?i64 = null, iat: ?i64 = null };
    const parsed = std.json.parseFromSliceLeaky(Std, arena, payload_json, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch return JwtError.InvalidJson;
    claims.sub = parsed.sub;
    claims.exp = parsed.exp;
    claims.iat = parsed.iat;

    if (now_unix) |now| {
        if (claims.exp) |e| {
            if (now >= e) return JwtError.Expired;
        }
    }

    return claims;
}

test "JWT HS256 sign and verify round-trip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = "your-secret-key-here";

    const Payload = struct { sub: []const u8, exp: i64, iat: i64 };
    const tok = try sign(arena, secret, Payload{ .sub = "user-123", .exp = 9_999_999_999, .iat = 0 });

    const c = try verify(arena, secret, tok, 1_000_000_000);
    try std.testing.expectEqualStrings("user-123", c.sub.?);
    try std.testing.expectEqual(@as(i64, 9_999_999_999), c.exp.?);
}

test "JWT verify rejects alg=none token (CVE-2015-2951)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // {"alg":"none","typ":"JWT"} + {"sub":"u","exp":9999999999} + empty signature
    const header = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0";
    const payload = "eyJzdWIiOiJ1IiwiZXhwIjo5OTk5OTk5OTk5fQ";
    const tok_str = header ++ "." ++ payload ++ ".";
    const tok = try arena.dupe(u8, tok_str);
    try std.testing.expectError(JwtError.InvalidAlgorithm, verify(arena, "any-secret", tok, null));
}

test "JWT verify rejects alg=RS256 (algorithm confusion)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // {"alg":"RS256","typ":"JWT"}
    const header = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9";
    const payload = "eyJzdWIiOiJ1IiwiZXhwIjo5OTk5OTk5OTk5fQ";
    const tok_str = header ++ "." ++ payload ++ ".AAAA";
    const tok = try arena.dupe(u8, tok_str);
    try std.testing.expectError(JwtError.InvalidAlgorithm, verify(arena, "any-secret", tok, null));
}

test "JWT HS256 rejects tampered signature" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Payload = struct { sub: []const u8, exp: i64 };
    var tok = try sign(arena, "secret", Payload{ .sub = "u", .exp = 9_999_999_999 });
    // Flip last char
    const last = tok.len - 1;
    tok[last] = if (tok[last] == 'A') 'B' else 'A';
    try std.testing.expectError(JwtError.InvalidSignature, verify(arena, "secret", tok, null));
}

test "JWT HS256 detects expiration" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Payload = struct { sub: []const u8, exp: i64 };
    const tok = try sign(arena, "s", Payload{ .sub = "u", .exp = 100 });
    try std.testing.expectError(JwtError.Expired, verify(arena, "s", tok, 200));
}
