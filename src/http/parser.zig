const std = @import("std");
const req = @import("request.zig");
const status = @import("status.zig");

pub const ParseError = error{
    InvalidRequestLine,
    InvalidHeader,
    UnknownMethod,
    HeadersTooLarge,
    BodyTooLarge,
    UnsupportedTransferEncoding,
    /// RFC 9112 §6.1 — Content-Length and Transfer-Encoding both present,
    /// or Content-Length appears more than once with conflicting values.
    /// We reject any such request to avoid HTTP request smuggling.
    AmbiguousFraming,
    Incomplete,
    OutOfMemory,
};

pub const Limits = struct {
    max_headers: usize = 64,
    max_request_bytes: usize = 64 * 1024,
    max_body_bytes: usize = 4 * 1024 * 1024,
};

/// Parse an HTTP/1.1 request from raw bytes.
/// `bytes` must contain at least the request-line + headers + CRLFCRLF.
/// The body is read up to Content-Length (chunked encoding is decoded into arena).
pub fn parseRequest(
    arena: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
) ParseError!struct { request: req.Request, consumed: usize } {
    if (bytes.len > limits.max_request_bytes) return ParseError.HeadersTooLarge;

    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return ParseError.Incomplete;
    const head = bytes[0..head_end];
    const body_start = head_end + 4;

    var line_iter = std.mem.splitSequence(u8, head, "\r\n");
    const first = line_iter.next() orelse return ParseError.InvalidRequestLine;

    var parts = std.mem.splitScalar(u8, first, ' ');
    const method_str = parts.next() orelse return ParseError.InvalidRequestLine;
    const target = parts.next() orelse return ParseError.InvalidRequestLine;
    const version = parts.next() orelse return ParseError.InvalidRequestLine;
    if (parts.next() != null) return ParseError.InvalidRequestLine;

    const method = status.Method.parse(method_str) orelse return ParseError.UnknownMethod;

    var path: []const u8 = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        path = target[0..q];
        query = target[q + 1 ..];
    }

    var headers: std.ArrayList(req.Header) = .empty;
    try headers.ensureTotalCapacity(arena, 16);

    var keep_alive = std.mem.eql(u8, version, "HTTP/1.1");
    var content_length: ?usize = null;
    var cl_seen: bool = false; // ensure no conflicting duplicate
    var chunked: bool = false;
    var transfer_encoding_seen: bool = false;

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (headers.items.len >= limits.max_headers) return ParseError.HeadersTooLarge;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return ParseError.InvalidHeader;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) return ParseError.InvalidHeader;

        headers.appendAssumeCapacity(.{ .name = name, .value = value });

        if (req.eqlIgnoreCase(name, "content-length")) {
            // Reject multiple Content-Length headers with conflicting values
            // (RFC 9112 §6.3-4). Identical duplicates are still allowed.
            const parsed_cl = std.fmt.parseInt(usize, value, 10) catch return ParseError.InvalidHeader;
            if (cl_seen) {
                if (content_length.? != parsed_cl) return ParseError.AmbiguousFraming;
            } else {
                content_length = parsed_cl;
                cl_seen = true;
            }
        } else if (req.eqlIgnoreCase(name, "transfer-encoding")) {
            transfer_encoding_seen = true;
            // We only support `chunked`; anything else (gzip,deflate,...) is rejected.
            if (!isOnlyChunked(value)) return ParseError.UnsupportedTransferEncoding;
            chunked = true;
        } else if (req.eqlIgnoreCase(name, "connection")) {
            if (req.containsIgnoreCase(value, "close")) keep_alive = false;
            if (req.containsIgnoreCase(value, "keep-alive")) keep_alive = true;
        }
    }

    // RFC 9112 §6.1: if both Transfer-Encoding and Content-Length are present,
    // the request is malformed — close the connection and reject.
    if (transfer_encoding_seen and cl_seen) return ParseError.AmbiguousFraming;

    var body: []const u8 = "";
    var consumed: usize = body_start;

    if (chunked) {
        const decoded = try decodeChunked(arena, bytes[body_start..], limits);
        body = decoded.body;
        consumed = body_start + decoded.consumed;
    } else if (content_length) |cl| {
        if (cl > limits.max_body_bytes) return ParseError.BodyTooLarge;
        if (bytes.len < body_start + cl) return ParseError.Incomplete;
        body = bytes[body_start .. body_start + cl];
        consumed = body_start + cl;
    }

    return .{
        .request = .{
            .method = method,
            .raw_method = method_str,
            .path = path,
            .query = query,
            .version = version,
            .headers = headers.items,
            .body = body,
            .keep_alive = keep_alive,
        },
        .consumed = consumed,
    };
}

const ChunkedResult = struct { body: []const u8, consumed: usize };

fn decodeChunked(arena: std.mem.Allocator, buf: []const u8, limits: Limits) ParseError!ChunkedResult {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, 256);

    var i: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, buf, i, "\r\n") orelse return ParseError.Incomplete;
        const size_line = buf[i..line_end];
        const semi = std.mem.indexOfScalar(u8, size_line, ';');
        const size_str = if (semi) |s| size_line[0..s] else size_line;
        const trimmed = std.mem.trim(u8, size_str, " \t");
        const size = std.fmt.parseInt(usize, trimmed, 16) catch return ParseError.InvalidHeader;
        i = line_end + 2;

        if (size == 0) {
            const trailer_end = std.mem.indexOfPos(u8, buf, i, "\r\n") orelse return ParseError.Incomplete;
            // Optionally skip trailer headers until empty line
            var j = i;
            while (true) {
                const le = std.mem.indexOfPos(u8, buf, j, "\r\n") orelse return ParseError.Incomplete;
                if (le == j) {
                    i = j + 2;
                    break;
                }
                j = le + 2;
            }
            _ = trailer_end;
            break;
        }

        if (i + size + 2 > buf.len) return ParseError.Incomplete;
        if (out.items.len + size > limits.max_body_bytes) return ParseError.BodyTooLarge;

        try out.appendSlice(arena, buf[i .. i + size]);
        i += size;
        if (!std.mem.eql(u8, buf[i .. i + 2], "\r\n")) return ParseError.InvalidHeader;
        i += 2;
    }

    return .{ .body = out.items, .consumed = i };
}

/// Find end of headers (CRLFCRLF). Returns null if not yet complete.
pub fn headersEnd(buf: []const u8) ?usize {
    return std.mem.indexOf(u8, buf, "\r\n\r\n");
}

/// True iff the Transfer-Encoding value is exactly `chunked` (case-insensitive,
/// surrounding whitespace allowed). Compound encodings like `gzip, chunked` or
/// `chunked, gzip` are intentionally rejected — we don't decode compression here.
fn isOnlyChunked(value: []const u8) bool {
    var trimmed = value;
    // Strip surrounding whitespace
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) trimmed = trimmed[1..];
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == ' ' or trimmed[trimmed.len - 1] == '\t')) trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len != "chunked".len) return false;
    return std.ascii.eqlIgnoreCase(trimmed, "chunked");
}

test "rejects Content-Length + Transfer-Encoding simultaneously (smuggling)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "POST / HTTP/1.1\r\nhost: a\r\ncontent-length: 5\r\ntransfer-encoding: chunked\r\n\r\n0\r\n\r\n";
    try std.testing.expectError(ParseError.AmbiguousFraming, parseRequest(arena, bytes, .{}));
}

test "rejects conflicting duplicate Content-Length" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "POST / HTTP/1.1\r\nhost: a\r\ncontent-length: 5\r\ncontent-length: 7\r\n\r\nhelloxx";
    try std.testing.expectError(ParseError.AmbiguousFraming, parseRequest(arena, bytes, .{}));
}

test "rejects unsupported Transfer-Encoding (gzip,chunked)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "POST / HTTP/1.1\r\nhost: a\r\ntransfer-encoding: gzip, chunked\r\n\r\n0\r\n\r\n";
    try std.testing.expectError(ParseError.UnsupportedTransferEncoding, parseRequest(arena, bytes, .{}));
}
