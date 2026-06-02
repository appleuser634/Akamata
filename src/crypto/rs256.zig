const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const is_native = build_options.backend == .native;
const has_openssl = is_native and build_options.with_openssl;

pub const Rs256Error = error{
    PemDecodeFailed,
    KeyLoadFailed,
    SignFailed,
    UnsupportedOnTarget,
    OutOfMemory,
};

/// Sign `message` with the given PEM-encoded RSA private key and return the
/// raw signature bytes.
///
/// - Native + `-Dopenssl=true`: uses OpenSSL via `@cImport("openssl/evp.h")`.
///   Required for FCM JWT signing. Zig 0.16 std.crypto only verifies
///   PKCS#1 v1.5 — it has no RSA sign — so OpenSSL stays opt-in here.
/// - Native default / Workers: not available. The JS host (Workers) signs
///   JWTs with the Crypto API; for native FCM you must opt-in to OpenSSL.
pub fn signPem(
    gpa: std.mem.Allocator,
    pem_private_key: []const u8,
    message: []const u8,
) Rs256Error![]u8 {
    if (!has_openssl) return Rs256Error.UnsupportedOnTarget;
    return nativeSign(gpa, pem_private_key, message);
}

const c = if (has_openssl) @cImport({
    @cInclude("openssl/bio.h");
    @cInclude("openssl/evp.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/err.h");
}) else struct {};

fn nativeSign(
    gpa: std.mem.Allocator,
    pem: []const u8,
    message: []const u8,
) Rs256Error![]u8 {
    if (!has_openssl) return Rs256Error.UnsupportedOnTarget;

    const bio = c.BIO_new_mem_buf(pem.ptr, @intCast(pem.len));
    if (bio == null) return Rs256Error.PemDecodeFailed;
    defer _ = c.BIO_free(bio);

    const pkey = c.PEM_read_bio_PrivateKey(bio, null, null, null);
    if (pkey == null) return Rs256Error.KeyLoadFailed;
    defer c.EVP_PKEY_free(pkey);

    const ctx = c.EVP_MD_CTX_new();
    if (ctx == null) return Rs256Error.SignFailed;
    defer c.EVP_MD_CTX_free(ctx);

    if (c.EVP_DigestSignInit(ctx, null, c.EVP_sha256(), null, pkey) != 1) {
        return Rs256Error.SignFailed;
    }
    if (c.EVP_DigestSignUpdate(ctx, message.ptr, message.len) != 1) {
        return Rs256Error.SignFailed;
    }
    var sig_len: usize = 0;
    if (c.EVP_DigestSignFinal(ctx, null, &sig_len) != 1) return Rs256Error.SignFailed;

    const sig = try gpa.alloc(u8, sig_len);
    errdefer gpa.free(sig);
    if (c.EVP_DigestSignFinal(ctx, sig.ptr, &sig_len) != 1) return Rs256Error.SignFailed;
    return sig[0..sig_len];
}

/// Build a Google service-account access token JWT and sign it.
/// Returns the JWT (header.payload.signature) base64url-joined.
///
/// `now_unix` is when the JWT was minted; `exp` defaults to now+3600.
pub fn buildGoogleJwt(
    arena: std.mem.Allocator,
    pem_private_key: []const u8,
    iss: []const u8, // service account client_email
    scope: []const u8, // e.g. "https://www.googleapis.com/auth/firebase.messaging"
    aud: []const u8, // "https://oauth2.googleapis.com/token"
    now_unix: i64,
    ttl_secs: i64,
) ![]u8 {
    const b64url = std.base64.url_safe_no_pad;
    const header = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const Payload = struct {
        iss: []const u8,
        scope: []const u8,
        aud: []const u8,
        exp: i64,
        iat: i64,
    };
    var payload_buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &payload_buf);
    defer payload_buf = aw.toArrayList();
    try std.json.Stringify.value(Payload{
        .iss = iss,
        .scope = scope,
        .aud = aud,
        .exp = now_unix + ttl_secs,
        .iat = now_unix,
    }, .{}, &aw.writer);
    const payload_json = aw.writer.buffered();

    const h_enc = b64url.Encoder.calcSize(header.len);
    const p_enc = b64url.Encoder.calcSize(payload_json.len);
    var input = try arena.alloc(u8, h_enc + 1 + p_enc);
    _ = b64url.Encoder.encode(input[0..h_enc], header);
    input[h_enc] = '.';
    _ = b64url.Encoder.encode(input[h_enc + 1 ..], payload_json);

    const sig = try signPem(arena, pem_private_key, input);

    const s_enc = b64url.Encoder.calcSize(sig.len);
    var out = try arena.alloc(u8, input.len + 1 + s_enc);
    @memcpy(out[0..input.len], input);
    out[input.len] = '.';
    _ = b64url.Encoder.encode(out[input.len + 1 ..], sig);
    return out;
}
