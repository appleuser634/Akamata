//! ETag generator + 304 Not Modified rewriter.
//!
//! After the handler runs, hashes the response body with SHA-256 and sets
//! a strong `ETag: "<hex>"` header. If the request's `If-None-Match` lists
//! a matching ETag, the response is rewritten to 304 with an empty body —
//! saving the actual payload bytes on the wire.
//!
//! Streaming responses are skipped (the body is already on the wire).
//! Non-2xx responses are also skipped (304 only applies to successful
//! representations, and we don't want to ETag error envelopes).

const std = @import("std");
const app_mod = @import("../app.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Options = struct {
    /// Skip ETag generation for bodies smaller than this. Tiny payloads
    /// don't benefit from conditional caching.
    min_bytes: usize = 32,
};

pub fn etag(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            try next.run(c);

            if (c.res.streaming != null) return;
            if (c.res.status_code < 200 or c.res.status_code >= 300) return;
            if (c.res.body.items.len < opts.min_bytes) return;

            // Don't override a handler-provided ETag.
            for (c.res.headers.items) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "etag")) {
                    // Still check If-None-Match against handler's tag.
                    return checkAndRewrite(c, h.value);
                }
            }

            // Compute strong ETag. We use the full SHA-256 hex digest, prefixed
            // by W/ → strong tag (no W/) since we hash the exact bytes.
            var hash: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(c.res.body.items, &hash, .{});
            const tag = try std.fmt.allocPrint(c.arena, "\"{x}\"", .{hash});
            try c.res.header("etag", tag);
            return checkAndRewrite(c, tag);
        }

        fn checkAndRewrite(c: *app_mod.App(State).Ctx, tag: []const u8) !void {
            const inm = c.req.header("if-none-match") orelse return;
            if (matches(inm, tag)) {
                // 304 has no body, but we keep ETag + Cache-Control etc.
                // Strip content-type / length headers that no longer apply.
                c.res.setStatus(304);
                c.res.body.clearRetainingCapacity();
                stripHeaders(&c.res.headers, &.{ "content-type", "content-length" });
            }
        }

        fn stripHeaders(headers: *std.ArrayList(@import("../http/response.zig").Header), names: []const []const u8) void {
            var i: usize = 0;
            while (i < headers.items.len) {
                const h = headers.items[i];
                var drop = false;
                for (names) |n| {
                    if (std.ascii.eqlIgnoreCase(h.name, n)) {
                        drop = true;
                        break;
                    }
                }
                if (drop) {
                    _ = headers.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    };
    return .{ .name = "etag", .call = Impl.call };
}

/// Does the comma-separated `if_none_match` header contain `tag` or `*`?
fn matches(if_none_match: []const u8, tag: []const u8) bool {
    if (std.mem.indexOf(u8, if_none_match, "*") != null) return true;
    var it = std.mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        // Strip a W/ prefix on either side — both are considered equal for
        // weak-vs-strong comparison via the "weak comparison function". We
        // don't currently emit weak tags but accept them in If-None-Match.
        const strip = if (std.mem.startsWith(u8, t, "W/")) t[2..] else t;
        const strip_tag = if (std.mem.startsWith(u8, tag, "W/")) tag[2..] else tag;
        if (std.mem.eql(u8, strip, strip_tag)) return true;
    }
    return false;
}

test "matches: exact hit" {
    try std.testing.expect(matches("\"abc\"", "\"abc\""));
    try std.testing.expect(matches("\"abc\", \"def\"", "\"def\""));
}

test "matches: weak vs strong" {
    try std.testing.expect(matches("W/\"abc\"", "\"abc\""));
    try std.testing.expect(matches("\"abc\"", "W/\"abc\""));
}

test "matches: wildcard" {
    try std.testing.expect(matches("*", "\"anything\""));
}

test "matches: miss" {
    try std.testing.expect(!matches("\"abc\"", "\"xyz\""));
}
