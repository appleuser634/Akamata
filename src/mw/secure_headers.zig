//! Auto-injects a baseline set of security response headers.
//!
//! Defaults are tuned for a JSON API (no inline scripts / styles). Override
//! `content_security_policy` for HTML-serving apps. Any field set to `null`
//! disables that specific header — useful when a reverse proxy already
//! injects it.
//!
//! Comparable Express middleware is "helmet"; the defaults here mirror
//! helmet's recommended preset minus features that don't apply to APIs.

const std = @import("std");
const app_mod = @import("../app.zig");

pub const Options = struct {
    /// HSTS. Tells browsers to use HTTPS for max-age seconds.
    /// Default 1 year + includeSubDomains. Set to null to omit.
    strict_transport_security: ?[]const u8 = "max-age=31536000; includeSubDomains",

    /// CSP. For a JSON API the spec value just blocks inline content from
    /// rendering even if the response is accidentally served as HTML.
    /// HTML apps should pass something like
    /// `default-src 'self'; script-src 'self' 'unsafe-inline'`.
    content_security_policy: ?[]const u8 = "default-src 'none'; frame-ancestors 'none'",

    /// Clickjacking protection. "DENY" wins over CSP's frame-ancestors on
    /// legacy browsers that don't implement CSP 2.
    x_frame_options: ?[]const u8 = "DENY",

    /// MIME-sniffing protection.
    x_content_type_options: ?[]const u8 = "nosniff",

    /// Cross-origin referrer leak protection. "no-referrer" is the strictest.
    referrer_policy: ?[]const u8 = "no-referrer",

    /// Permissions-Policy (formerly Feature-Policy). Default disables every
    /// powerful surface API. Override for apps that need camera/geolocation.
    permissions_policy: ?[]const u8 = "camera=(), microphone=(), geolocation=(), interest-cohort=()",

    /// Cross-Origin-Opener-Policy. "same-origin" isolates browsing contexts.
    cross_origin_opener_policy: ?[]const u8 = "same-origin",

    /// Cross-Origin-Resource-Policy. "same-site" is a reasonable default for
    /// APIs that allow same-site embeds; tighten to "same-origin" if you
    /// don't host any subdomain.
    cross_origin_resource_policy: ?[]const u8 = "same-site",
};

pub fn secureHeaders(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            try next.run(c);
            // Set headers post-handler so streaming handlers that already
            // committed headers aren't disrupted. For buffered responses
            // this is equivalent to setting them before next.run.
            if (c.res.streaming != null) return;
            inline for (.{
                .{ "strict-transport-security", opts.strict_transport_security },
                .{ "content-security-policy", opts.content_security_policy },
                .{ "x-frame-options", opts.x_frame_options },
                .{ "x-content-type-options", opts.x_content_type_options },
                .{ "referrer-policy", opts.referrer_policy },
                .{ "permissions-policy", opts.permissions_policy },
                .{ "cross-origin-opener-policy", opts.cross_origin_opener_policy },
                .{ "cross-origin-resource-policy", opts.cross_origin_resource_policy },
            }) |pair| {
                const name = pair[0];
                const value = pair[1];
                if (value) |v| try c.header(name, v);
            }
        }
    };
    return .{ .name = "secure_headers", .call = Impl.call };
}
