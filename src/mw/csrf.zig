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
const cookie_mod = @import("../http/cookie.zig");

const b64url = std.base64.url_safe_no_pad;

pub const Options = struct {
    cookie_name: []const u8 = "akamata_csrf",
    header_name: []const u8 = "x-csrf-token",
    cookie_path: []const u8 = "/",
    cookie_secure: bool = false,
    cookie_same_site: cookie_mod.SameSite = .lax,
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
                }
                return next.run(c);
            }

            // Unsafe method: cookie + header must match.
            const cookie_v = existing orelse return reject(c, "csrf_cookie_missing");
            const header_v = c.req.header(opts.header_name) orelse return reject(c, "csrf_header_missing");
            if (cookie_v.len != header_v.len) return reject(c, "csrf_token_mismatch");
            if (!std.crypto.timing_safe.eql(u8, cookie_v[0..0], header_v[0..0])) {
                // Same-length but not byte-for-byte equal — also reject.
                if (!constantTimeEq(cookie_v, header_v)) return reject(c, "csrf_token_mismatch");
            } else if (!constantTimeEq(cookie_v, header_v)) {
                return reject(c, "csrf_token_mismatch");
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

        fn constantTimeEq(a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return false;
            var diff: u8 = 0;
            for (a, b) |x, y| diff |= x ^ y;
            return diff == 0;
        }

        fn mintToken(arena: std.mem.Allocator) ![]u8 {
            var raw: [24]u8 = undefined;
            const Rand = struct { extern "c" fn arc4random_buf(buf: [*]u8, n: usize) void; };
            Rand.arc4random_buf(&raw, raw.len);
            const enc_len = b64url.Encoder.calcSize(raw.len);
            const out = try arena.alloc(u8, enc_len);
            _ = b64url.Encoder.encode(out, &raw);
            return out;
        }
    };
    return .{ .name = "csrf", .call = Impl.call };
}
