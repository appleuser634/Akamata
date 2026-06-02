//! HTTP content negotiation (RFC 9110 §12.5).
//!
//! Parses the request's `Accept` header (with q-value preference) and picks
//! the best match from a server-side allow-list. Wildcard tokens (`*/*`,
//! `text/*`) are honored.
//!
//! The negotiation is intentionally simple: it returns the first server
//! candidate that has the highest weighted score, breaking ties by server
//! preference order. This mirrors the behavior of Express's `req.accepts()`.

const std = @import("std");

const Match = struct {
    candidate_idx: usize,
    q: f32,
    /// Specificity bucket — fewer wildcards = better.
    /// 0: exact (type/subtype), 1: subtype wildcard, 2: full wildcard.
    specificity: u8,
};

/// Pick the best media type from `candidates` that satisfies `accept_header`.
/// Returns null if nothing matches (typical: `Accept: image/jpeg` against a
/// JSON-only API). Caller should respond with 406 Not Acceptable in that
/// case per RFC 9110.
///
/// `candidates` is searched in declaration order; ties in q × specificity
/// are broken by the candidates' order — so put your preferred default
/// first.
pub fn best(accept_header: ?[]const u8, candidates: []const []const u8) ?[]const u8 {
    // No Accept header is treated as `Accept: */*` per RFC.
    const accept = accept_header orelse "*/*";

    var best_match: ?Match = null;
    for (candidates, 0..) |cand, i| {
        if (matchAccept(accept, cand)) |m| {
            const winner = best_match == null or
                m.q > best_match.?.q or
                (m.q == best_match.?.q and m.specificity < best_match.?.specificity);
            if (winner) {
                best_match = .{
                    .candidate_idx = i,
                    .q = m.q,
                    .specificity = m.specificity,
                };
            }
        }
    }

    if (best_match) |m| return candidates[m.candidate_idx];
    return null;
}

const Score = struct { q: f32, specificity: u8 };

/// Does `media_type` (e.g. "application/json") match the `accept_header`?
/// If so, return the best (q, specificity) pair across all tokens in the
/// header.
fn matchAccept(accept: []const u8, media_type: []const u8) ?Score {
    var result: ?Score = null;

    var it = std.mem.splitScalar(u8, accept, ',');
    while (it.next()) |raw_tok| {
        const tok = trim(raw_tok);
        if (tok.len == 0) continue;

        // Split off ;q=... and any other params we ignore.
        var q: f32 = 1.0;
        const tok_type = blk: {
            const semi = std.mem.indexOfScalar(u8, tok, ';');
            if (semi) |i| {
                var p_it = std.mem.splitScalar(u8, tok[i + 1 ..], ';');
                while (p_it.next()) |param| {
                    const tp = trim(param);
                    if (std.mem.startsWith(u8, tp, "q=")) {
                        q = std.fmt.parseFloat(f32, tp[2..]) catch 1.0;
                    }
                }
                break :blk trim(tok[0..i]);
            }
            break :blk tok;
        };
        if (q <= 0.0) continue;

        const specificity = matchType(tok_type, media_type) orelse continue;
        if (result == null or q > result.?.q or
            (q == result.?.q and specificity < result.?.specificity))
        {
            result = .{ .q = q, .specificity = specificity };
        }
    }
    return result;
}

/// Returns specificity (0 exact, 1 subtype wildcard, 2 full wildcard) if
/// `accept_type` matches `media_type`, else null.
fn matchType(accept_type: []const u8, media_type: []const u8) ?u8 {
    if (std.mem.eql(u8, accept_type, "*/*")) return 2;

    const a_slash = std.mem.indexOfScalar(u8, accept_type, '/') orelse return null;
    const m_slash = std.mem.indexOfScalar(u8, media_type, '/') orelse return null;
    const a_type = accept_type[0..a_slash];
    const a_sub = accept_type[a_slash + 1 ..];
    const m_type = media_type[0..m_slash];
    const m_sub = media_type[m_slash + 1 ..];

    if (!std.ascii.eqlIgnoreCase(a_type, m_type)) return null;
    if (std.mem.eql(u8, a_sub, "*")) return 1;
    if (!std.ascii.eqlIgnoreCase(a_sub, m_sub)) return null;
    return 0;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

// ===== tests =====

test "best picks exact match" {
    const got = best("application/json", &.{ "text/html", "application/json" });
    try std.testing.expectEqualStrings("application/json", got.?);
}

test "best honors q-values" {
    // text/html;q=0.9 vs application/json;q=1.0 → json wins.
    const got = best(
        "text/html;q=0.9, application/json",
        &.{ "text/html", "application/json" },
    ).?;
    try std.testing.expectEqualStrings("application/json", got);
}

test "best honors specificity (exact beats wildcard)" {
    // Both candidates match */*; the request asks for application/json
    // exactly *and* */* — application/json should still win for the json
    // candidate due to specificity.
    const got = best(
        "application/json, */*;q=0.5",
        &.{ "text/html", "application/json" },
    ).?;
    try std.testing.expectEqualStrings("application/json", got);
}

test "best returns null when nothing matches" {
    const got = best("image/jpeg", &.{ "application/json", "text/html" });
    try std.testing.expectEqual(@as(?[]const u8, null), got);
}

test "best treats absent Accept as */*" {
    const got = best(null, &.{"application/json"}).?;
    try std.testing.expectEqualStrings("application/json", got);
}

test "best honors subtype wildcard" {
    const got = best("text/*", &.{ "application/json", "text/html" }).?;
    try std.testing.expectEqualStrings("text/html", got);
}

test "best skips q=0 candidates" {
    const got = best(
        "application/json;q=0, text/html",
        &.{ "application/json", "text/html" },
    ).?;
    try std.testing.expectEqualStrings("text/html", got);
}
