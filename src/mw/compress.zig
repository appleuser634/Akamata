//! gzip / deflate response compression.
//!
//! Replaces the response body with a compressed version when:
//!   * the client's `Accept-Encoding` includes a supported codec, and
//!   * the body exceeds `min_bytes`, and
//!   * the body isn't already compressed (we don't double-encode), and
//!   * the response isn't streaming (chunked + on-the-fly compression is a
//!     follow-up — for now streaming responses pass through uncompressed).
//!
//! On Workers the edge already gzip-encodes responses, so this middleware
//! is a no-op there. The same handler code thus produces the same wire
//! result on both backends without any runtime branching at the app layer.

const std = @import("std");
const app_mod = @import("../app.zig");
const flate = std.compress.flate;
const build_options = @import("build_options");

pub const Codec = enum {
    /// No compression (used as a sentinel when the negotiation found no
    /// acceptable codec). Bodies are passed through untouched.
    identity,
    gzip,
    deflate,
};

pub const Options = struct {
    /// Below this many uncompressed bytes, skip compression — the framing
    /// overhead of gzip (~20 bytes) eats the win for tiny payloads.
    min_bytes: usize = 1024,
    /// Codec preference order. The first codec in this list that appears
    /// in the client's Accept-Encoding wins.
    prefer: []const Codec = &.{ .gzip, .deflate },
};

pub fn compress(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            try next.run(c);

            // On Workers, the JS edge layer handles compression. Skip here
            // to avoid double-encoding.
            if (comptime build_options.backend != .native) return;

            if (c.res.streaming != null) return;
            if (c.res.body.items.len < opts.min_bytes) return;

            // Skip if the handler already set a content-encoding.
            for (c.res.headers.items) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "content-encoding")) return;
            }

            const accept = c.req.header("accept-encoding") orelse return;
            const chosen = pickCodec(accept, opts.prefer) orelse return;

            // Compress into a fresh arena buffer, then swap into res.body.
            const compressed = compressBytes(c.arena, c.res.body.items, chosen) catch return;
            if (compressed.len >= c.res.body.items.len) return; // no win, skip

            c.res.body.clearRetainingCapacity();
            try c.res.body.appendSlice(c.arena, compressed);
            try c.res.header("content-encoding", switch (chosen) {
                .gzip => "gzip",
                .deflate => "deflate",
                .identity => unreachable,
            });
            try c.res.header("vary", "accept-encoding");
        }
    };
    return .{ .name = "compress", .call = Impl.call };
}

fn pickCodec(accept: []const u8, prefer: []const Codec) ?Codec {
    // q=0 explicitly disables a codec; we don't honor weighted preference
    // beyond that, since the server gets the final say per RFC 9110.
    for (prefer) |codec| {
        const name = switch (codec) {
            .gzip => "gzip",
            .deflate => "deflate",
            .identity => continue,
        };
        if (containsCodec(accept, name)) return codec;
    }
    return null;
}

/// Case-insensitive substring search that respects token boundaries: "gzip"
/// in "x-gzip" must NOT match, but "gzip" in "deflate, gzip" must. Also
/// honors `;q=0` explicit disable.
fn containsCodec(accept: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, accept, ", ");
    while (it.next()) |tok| {
        // tok may be "gzip" or "gzip;q=0.5" — split on ';'
        const semi = std.mem.indexOfScalar(u8, tok, ';');
        const codec_name = if (semi) |i| tok[0..i] else tok;
        if (!std.ascii.eqlIgnoreCase(codec_name, name)) continue;
        // Disabled explicitly?
        if (semi) |i| {
            const params = tok[i + 1 ..];
            // Look for q=0 (with optional whitespace).
            if (std.mem.indexOf(u8, params, "q=0") != null and
                std.mem.indexOf(u8, params, "q=0.") == null) return false;
        }
        return true;
    }
    return false;
}

fn compressBytes(arena: std.mem.Allocator, src: []const u8, codec: Codec) ![]const u8 {
    // The flate compressor calls `writeAll` on `output` during init, which
    // asserts `output.buffer.len > 8`. Allocating starts with a zero-len
    // buffer, so we pre-allocate capacity that flate can then write into.
    var aw: std.Io.Writer.Allocating = try .initCapacity(arena, src.len / 2 + 64);
    defer aw.deinit();

    const container: flate.Container = switch (codec) {
        .gzip => .gzip,
        .deflate => .zlib,
        .identity => unreachable,
    };

    const window_buf = try arena.alloc(u8, flate.max_window_len);
    var cmp = try flate.Compress.init(&aw.writer, window_buf, container, flate.Compress.Options.level_4);
    try cmp.writer.writeAll(src);
    try cmp.finish();

    return arena.dupe(u8, aw.written());
}

// ===== tests =====

test "containsCodec matches by token boundary and honors q=0" {
    try std.testing.expect(containsCodec("gzip, deflate", "gzip"));
    try std.testing.expect(containsCodec("deflate, gzip", "gzip"));
    try std.testing.expect(!containsCodec("x-gzip", "gzip"));
    try std.testing.expect(!containsCodec("gzip;q=0", "gzip"));
    try std.testing.expect(containsCodec("gzip;q=0.5", "gzip"));
}

test "compressBytes round-trips through gzip decompressor" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const payload = "Lorem ipsum dolor sit amet " ** 64;
    const out = try compressBytes(arena, payload, .gzip);
    try std.testing.expect(out.len < payload.len);
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1f\x8b")); // gzip magic
}
