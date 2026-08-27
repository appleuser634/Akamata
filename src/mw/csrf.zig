// CSRF protection via the "double-submit cookie" pattern:
//
//   1. On a safe method (GET/HEAD/OPTIONS), mint a random token, set it
//      as both a JS-readable cookie and a header on the response.
//   2. On an unsafe method (POST/PUT/PATCH/DELETE), require an
//      `X-CSRF-Token` header (or `_csrf` form field, future work) that
//      matches the cookie. Reject with 403 otherwise.
//
// This is the same approach used by Hono, Express's csurf, and most modern
// frameworks. It works for SPA / fetch() callers without a server-side
// session, and stacks cleanly with the cookie-session middleware.

const std = @import("std");
const app_mod = @import("../app.zig");
const random = @import("../crypto/random.zig");
const cookie_mod = @import("../http/cookie.zig");
const crypto_util = @import("../crypto/util.zig");
const session_mod = @import("session.zig");

const b64url = std.base64.url_safe_no_pad;

/// Dynamic origin policy for applications whose public host varies by tenant.
/// It compares the serialized Origin authority with the request Host. Use it
/// as `origin_verifier`; host-rewriting proxies should provide their own hook.
pub fn originMatchesHost(request: @import("../http/request.zig").Request, _: *anyopaque) anyerror!bool {
    const origin = request.header("origin") orelse return false;
    const host = request.header("host") orelse return false;
    const marker = std.mem.indexOf(u8, origin, "://") orelse return false;
    const scheme = origin[0..marker];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    const authority = origin[marker + 3 ..];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "/?#@") != null) return false;
    return std.ascii.eqlIgnoreCase(authority, host);
}

pub const Options = struct {
    pub const OriginVerifier = *const fn (request: @import("../http/request.zig").Request, app_state: *anyopaque) anyerror!bool;
    pub const SessionVerifier = *const fn (request: @import("../http/request.zig").Request, app_state: *anyopaque, token: []const u8, token_hash: [64]u8) anyerror!bool;
    cookie_name: []const u8 = "akamata_csrf",
    header_name: []const u8 = "x-csrf-token",
    cookie_path: []const u8 = "/",
    cookie_secure: bool = true,
    cookie_same_site: cookie_mod.SameSite = .lax,
    expected_origin: ?[]const u8 = null,
    /// Application hook for dynamic tenant/proxy-aware origin policy. It runs
    /// in addition to `expected_origin`, never instead of fetch metadata.
    origin_verifier: ?OriginVerifier = null,
    enforce_fetch_metadata: bool = true,
    bind_to_session: bool = false,
    /// Connect CSRF binding to an application-owned DB session schema. When
    /// set, this verifier replaces only the built-in cookie-session hash
    /// lookup. The double-submit and origin/fetch checks remain mandatory.
    session_verifier: ?SessionVerifier = null,
    /// Methods that bypass token verification (and on which a fresh token is
    /// minted if the cookie is missing).
    safe_methods: []const []const u8 = &[_][]const u8{ "GET", "HEAD", "OPTIONS" },
};

pub fn csrf(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const method_str = c.req.method();
            const safe = isSafeMethod(method_str);

            const existing = c.req.cookie(opts.cookie_name);
            if (safe) {
                // Mint and set if missing — clients can read this cookie and
                // echo it as the `X-CSRF-Token` header on subsequent writes.
                if (existing == null) {
                    const tok = try mintToken(c.arena);
                    try c.setCookie(opts.cookie_name, tok, .{
                        .path = opts.cookie_path,
                        .secure = opts.cookie_secure,
                        // CSRF cookie MUST be readable by client JS, so
                        // http_only = false on purpose.
                        .http_only = false,
                        .same_site = opts.cookie_same_site,
                    });
                    if (opts.bind_to_session) if (session_mod.currentSession(State, c)) |session| {
                        const digest = crypto_util.sha256Hex(tok);
                        try session.set("__csrf_hash", &digest);
                    };
                }
                return next.run(c);
            }

            if (opts.enforce_fetch_metadata) if (c.req.header("sec-fetch-site")) |site| {
                if (!std.ascii.eqlIgnoreCase(site, "same-origin") and !std.ascii.eqlIgnoreCase(site, "same-site") and !std.ascii.eqlIgnoreCase(site, "none")) return reject(c, "cross_site_request");
            };
            if (opts.expected_origin) |expected| {
                const origin = c.req.header("origin") orelse return reject(c, "origin_missing");
                if (!crypto_util.sameOrigin(origin, expected)) return reject(c, "origin_mismatch");
            }
            if (opts.origin_verifier) |verify| {
                if (!try verify(c.req.inner.*, @ptrCast(c.app_state))) return reject(c, "origin_mismatch");
            }

            // Unsafe method: cookie + header must match.
            const cookie_v = existing orelse return reject(c, "csrf_cookie_missing");
            const header_v = c.req.header(opts.header_name) orelse return reject(c, "csrf_header_missing");
            if (!crypto_util.timingSafeEqual(cookie_v, header_v)) return reject(c, "csrf_token_mismatch");
            const actual_hash = crypto_util.sha256Hex(cookie_v);
            if (opts.session_verifier) |verify| {
                if (!try verify(c.req.inner.*, @ptrCast(c.app_state), cookie_v, actual_hash)) return reject(c, "session_hash_mismatch");
            } else if (opts.bind_to_session) {
                const session = session_mod.currentSession(State, c) orelse return reject(c, "session_missing");
                const expected_hash = try session.get("__csrf_hash") orelse return reject(c, "session_hash_missing");
                if (!crypto_util.timingSafeEqual(expected_hash, &actual_hash)) return reject(c, "session_hash_mismatch");
            }
            return next.run(c);
        }

        fn isSafeMethod(method_str: []const u8) bool {
            for (opts.safe_methods) |m| {
                if (std.mem.eql(u8, m, method_str)) return true;
            }
            return false;
        }

        fn reject(c: *app_mod.App(State).Ctx, reason: []const u8) anyerror!void {
            return c.json(.{ .error_kind = "csrf", .reason = reason }, 403);
        }

        fn mintToken(arena: std.mem.Allocator) ![]u8 {
            var raw: [24]u8 = undefined;
            random.fill(&raw);
            const enc_len = b64url.Encoder.calcSize(raw.len);
            const out = try arena.alloc(u8, enc_len);
            _ = b64url.Encoder.encode(out, &raw);
            return out;
        }
    };
    return .{ .name = "csrf", .call = Impl.call };
}
