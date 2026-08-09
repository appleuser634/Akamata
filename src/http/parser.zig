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
    /// or Content-Length appears more than once.
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
    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return ParseError.Incomplete;
    // `max_request_bytes` historically names the header-section limit.  Do
    // not apply it to the complete request buffer: Workers hands this parser
    // headers and the full body in one slice, so doing so rejects ordinary
    // uploads as `HeadersTooLarge` once their body pushes the slice over 64 KiB.
    if (head_end > limits.max_request_bytes) return ParseError.HeadersTooLarge;
    const head = bytes[0..head_end];
    const body_start = head_end + 4;

    var line_iter = std.mem.splitSequence(u8, head, "\r\n");
    const first = line_iter.next() orelse return ParseError.InvalidRequestLine;

    if (std.mem.indexOfScalar(u8, first, '\r') != null or std.mem.indexOfScalar(u8, first, '\n') != null) return ParseError.InvalidRequestLine;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method_str = parts.next() orelse return ParseError.InvalidRequestLine;
    const target = parts.next() orelse return ParseError.InvalidRequestLine;
    const version = parts.next() orelse return ParseError.InvalidRequestLine;
    if (parts.next() != null) return ParseError.InvalidRequestLine;

    if (!(std.mem.eql(u8, version, "HTTP/1.1") or std.mem.eql(u8, version, "HTTP/1.0"))) return ParseError.InvalidRequestLine;
    if (!validRequestTarget(target)) return ParseError.InvalidRequestLine;

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
    var host_seen: bool = false;

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (headers.items.len >= limits.max_headers) return ParseError.HeadersTooLarge;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return ParseError.InvalidHeader;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!validFieldName(name) or !validFieldValue(value)) return ParseError.InvalidHeader;

        try headers.append(arena, .{ .name = name, .value = value });

        if (req.eqlIgnoreCase(name, "content-length")) {
            // Reject every duplicate. Normalizing identical duplicates has
            // caused parser differentials in intermediaries and is unnecessary.
            if (value.len == 0 or !allDecimal(value)) return ParseError.InvalidHeader;
            const parsed_cl = std.fmt.parseInt(usize, value, 10) catch return ParseError.InvalidHeader;
            if (cl_seen) return ParseError.AmbiguousFraming;
            content_length = parsed_cl;
            cl_seen = true;
        } else if (req.eqlIgnoreCase(name, "transfer-encoding")) {
            transfer_encoding_seen = true;
            // We only support `chunked`; anything else (gzip,deflate,...) is rejected.
            if (!isOnlyChunked(value)) return ParseError.UnsupportedTransferEncoding;
            chunked = true;
        } else if (req.eqlIgnoreCase(name, "connection")) {
            if (req.containsIgnoreCase(value, "close")) keep_alive = false;
            if (req.containsIgnoreCase(value, "keep-alive")) keep_alive = true;
        } else if (req.eqlIgnoreCase(name, "host")) {
            if (host_seen or !validHost(value)) return ParseError.InvalidHeader;
            host_seen = true;
        }
    }

    if (std.mem.eql(u8, version, "HTTP/1.1") and !host_seen) return ParseError.InvalidHeader;

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
        const body_end = std.math.add(usize, body_start, cl) catch return ParseError.BodyTooLarge;
        if (bytes.len < body_end) return ParseError.Incomplete;
        body = bytes[body_start..body_end];
        consumed = body_end;
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
        // Chunk extensions are not consumed by Akamata. Reject them instead
        // of risking a differential with an intermediary that interprets
        // extension quoting/escaping differently.
        if (semi != null) return ParseError.InvalidHeader;
        const size_str = if (semi) |s| size_line[0..s] else size_line;
        if (size_str.len == 0 or !allHex(size_str)) return ParseError.InvalidHeader;
        const size = std.fmt.parseInt(usize, size_str, 16) catch return ParseError.InvalidHeader;
        i = std.math.add(usize, line_end, 2) catch return ParseError.InvalidHeader;

        if (size == 0) {
            // Optionally skip trailer headers until empty line
            var j = i;
            while (true) {
                const le = std.mem.indexOfPos(u8, buf, j, "\r\n") orelse return ParseError.Incomplete;
                if (le == j) {
                    i = std.math.add(usize, j, 2) catch return ParseError.InvalidHeader;
                    break;
                }
                const trailer = buf[j..le];
                const colon = std.mem.indexOfScalar(u8, trailer, ':') orelse return ParseError.InvalidHeader;
                const name = trailer[0..colon];
                const value = std.mem.trim(u8, trailer[colon + 1 ..], " \t");
                if (!validFieldName(name) or !validFieldValue(value)) return ParseError.InvalidHeader;
                if (req.eqlIgnoreCase(name, "content-length") or req.eqlIgnoreCase(name, "transfer-encoding") or req.eqlIgnoreCase(name, "host")) return ParseError.InvalidHeader;
                j = std.math.add(usize, le, 2) catch return ParseError.InvalidHeader;
            }
            break;
        }

        const data_end = std.math.add(usize, i, size) catch return ParseError.BodyTooLarge;
        const framed_end = std.math.add(usize, data_end, 2) catch return ParseError.BodyTooLarge;
        if (framed_end > buf.len) return ParseError.Incomplete;
        const output_end = std.math.add(usize, out.items.len, size) catch return ParseError.BodyTooLarge;
        if (output_end > limits.max_body_bytes) return ParseError.BodyTooLarge;

        try out.appendSlice(arena, buf[i..data_end]);
        i = data_end;
        if (!std.mem.eql(u8, buf[i .. i + 2], "\r\n")) return ParseError.InvalidHeader;
        i += 2;
    }

    return .{ .body = out.items, .consumed = i };
}

fn validFieldName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| switch (ch) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~', '0'...'9', 'A'...'Z', 'a'...'z' => {},
        else => return false,
    };
    return true;
}

fn validFieldValue(value: []const u8) bool {
    for (value) |ch| if (ch == '\r' or ch == '\n' or ch == 0 or (ch < 0x20 and ch != '\t') or ch == 0x7f) return false;
    return true;
}

fn validRequestTarget(target: []const u8) bool {
    if (target.len == 0 or target[0] != '/') return false;
    var i: usize = 0;
    while (i < target.len) : (i += 1) {
        const ch = target[i];
        if (ch <= 0x20 or ch == 0x7f or ch == '#') return false;
        if (ch == '%') {
            if (i + 2 >= target.len or !std.ascii.isHex(target[i + 1]) or !std.ascii.isHex(target[i + 2])) return false;
            i += 2;
        }
    }
    return true;
}

fn validHost(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse return false;
        if (close <= 1) return false;
        for (value[1..close]) |ch| if (!(std.ascii.isHex(ch) or ch == ':' or ch == '.')) return false;
        if (close + 1 == value.len) return true;
        return value[close + 1] == ':' and validPort(value[close + 2 ..]);
    }
    if (std.mem.count(u8, value, ":") > 1) return false;
    const colon = std.mem.lastIndexOfScalar(u8, value, ':');
    const host = if (colon) |at| value[0..at] else value;
    if (colon) |at| if (!validPort(value[at + 1 ..])) return false;
    if (host.len == 0 or host[0] == '.' or host[host.len - 1] == '.') return false;
    var label_start: usize = 0;
    for (host, 0..) |ch, i| {
        if (ch == '.') {
            if (i == label_start or host[i - 1] == '-') return false;
            label_start = i + 1;
        } else if (!(std.ascii.isAlphanumeric(ch) or ch == '-')) return false;
        if (i == label_start and ch == '-') return false;
    }
    return host[host.len - 1] != '-';
}

fn validPort(port: []const u8) bool {
    if (port.len == 0 or port.len > 5 or !allDecimal(port)) return false;
    const number = std.fmt.parseInt(u16, port, 10) catch return false;
    return number != 0;
}

fn allHex(value: []const u8) bool {
    for (value) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn allDecimal(value: []const u8) bool {
    for (value) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
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

test "strict header and host validation rejects smuggling differentials" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][]const u8{
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length : 0\r\n\r\n",
        "GET / HTTP/1.1\r\nHost : a\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\n folded: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
        "GET / HTTP/2.0\r\nHost: a\r\n\r\n",
        "GET relative HTTP/1.1\r\nHost: a\r\n\r\n",
        "GET / HTTP/1.1\nHost: a\n\n",
    };
    for (cases) |bytes| {
        if (parseRequest(arena, bytes, .{})) |_| return error.TestExpectedError else |_| {}
    }
}

test "chunk size overflow is rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const bytes = "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\r\n";
    try std.testing.expectError(ParseError.InvalidHeader, parseRequest(arena_state.allocator(), bytes, .{}));
}

test "rejects unsupported Transfer-Encoding (gzip,chunked)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "POST / HTTP/1.1\r\nhost: a\r\ntransfer-encoding: gzip, chunked\r\n\r\n0\r\n\r\n";
    try std.testing.expectError(ParseError.UnsupportedTransferEncoding, parseRequest(arena, bytes, .{}));
}

test "header limit does not include request body" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "x" ** (65 * 1024);
    const request = "POST /upload HTTP/1.1\r\nhost: example.com\r\ncontent-length: 66560\r\n\r\n" ++ body;
    const parsed = try parseRequest(arena, request, .{});

    try std.testing.expectEqual(@as(usize, body.len), parsed.request.body.len);
}
