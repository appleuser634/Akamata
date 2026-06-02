// multipart/form-data parser (RFC 7578).
//
// Constructs an in-memory list of `Part`s from a raw request body.
// Streaming variants can come later; for typical API use the whole body
// already lives in the request arena anyway.

const std = @import("std");

pub const MultipartError = error{
    BoundaryMissing,
    BoundaryTooLarge,
    InvalidFormat,
    InvalidHeader,
    OutOfMemory,
};

pub const Part = struct {
    /// Form field name (`name="..."` in Content-Disposition).
    name: []const u8,
    /// Original filename if the part was a file upload, else null.
    filename: ?[]const u8 = null,
    /// `Content-Type` header value, or `null` if absent.
    content_type: ?[]const u8 = null,
    /// Raw body bytes. Slice into the arena passed to `parse`.
    data: []const u8,
};

pub const Parsed = struct {
    parts: []const Part,

    /// First part with the given field name, or null.
    pub fn field(self: Parsed, name: []const u8) ?Part {
        for (self.parts) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// First part whose name matches AND whose filename is non-null.
    pub fn file(self: Parsed, name: []const u8) ?Part {
        for (self.parts) |p| {
            if (std.mem.eql(u8, p.name, name) and p.filename != null) return p;
        }
        return null;
    }

    /// All parts with the given field name (e.g. multi-select uploads).
    pub fn all(self: Parsed, arena: std.mem.Allocator, name: []const u8) ![]const Part {
        var out: std.ArrayList(Part) = .empty;
        for (self.parts) |p| {
            if (std.mem.eql(u8, p.name, name)) try out.append(arena, p);
        }
        return out.toOwnedSlice(arena);
    }
};

/// Extract `boundary=...` from a `Content-Type: multipart/...; boundary=XYZ`
/// header value. Returns the boundary string (without quotes) or null.
pub fn boundaryFromContentType(content_type: []const u8) ?[]const u8 {
    var rest = content_type;
    while (std.mem.indexOfScalar(u8, rest, ';')) |semi| {
        rest = std.mem.trim(u8, rest[semi + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, "boundary=")) {
            var v = rest[9..];
            // boundary can run to end-of-string or next ';'
            if (std.mem.indexOfScalar(u8, v, ';')) |s| v = v[0..s];
            v = std.mem.trim(u8, v, " \t");
            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
            return v;
        }
    }
    return null;
}

/// Parse a multipart/form-data body. The returned `Part` slices point into
/// `body`, so `body` must outlive the result (typically by sitting in the
/// per-request arena alongside this call).
pub fn parse(arena: std.mem.Allocator, body: []const u8, boundary: []const u8) MultipartError!Parsed {
    if (boundary.len == 0) return MultipartError.BoundaryMissing;
    if (boundary.len > 200) return MultipartError.BoundaryTooLarge;

    // Build the "--boundary" delimiter once.
    var delim_buf: std.ArrayList(u8) = .empty;
    defer delim_buf.deinit(arena);
    try delim_buf.appendSlice(arena, "--");
    try delim_buf.appendSlice(arena, boundary);
    const delim = delim_buf.items;

    var parts: std.ArrayList(Part) = .empty;

    // Locate first delimiter. Anything before it is the "preamble" and we drop.
    var i = std.mem.indexOf(u8, body, delim) orelse return MultipartError.InvalidFormat;
    i += delim.len;
    while (true) {
        // After a delim we expect either CRLF (next part) or "--" then optional trailer (end).
        if (i + 2 <= body.len and body[i] == '-' and body[i + 1] == '-') {
            // Closing delimiter; we're done.
            break;
        }
        if (i + 2 > body.len) return MultipartError.InvalidFormat;
        if (body[i] != '\r' or body[i + 1] != '\n') return MultipartError.InvalidFormat;
        i += 2;

        // Parse headers up to the empty CRLFCRLF.
        const headers_end = std.mem.indexOfPos(u8, body, i, "\r\n\r\n") orelse return MultipartError.InvalidFormat;
        const headers_slice = body[i..headers_end];
        i = headers_end + 4;

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var ctype: ?[]const u8 = null;

        var header_iter = std.mem.splitSequence(u8, headers_slice, "\r\n");
        while (header_iter.next()) |hline| {
            const colon = std.mem.indexOfScalar(u8, hline, ':') orelse return MultipartError.InvalidHeader;
            const hname = std.mem.trim(u8, hline[0..colon], " \t");
            const hvalue = std.mem.trim(u8, hline[colon + 1 ..], " \t");
            if (eqlIgnoreCase(hname, "content-disposition")) {
                parseContentDisposition(hvalue, &name, &filename);
            } else if (eqlIgnoreCase(hname, "content-type")) {
                ctype = hvalue;
            }
        }
        if (name == null) return MultipartError.InvalidHeader;

        // Find end of the part body (the next delim, preceded by CRLF).
        // Per RFC, the boundary is CRLF-prefixed in the body.
        const search_from = i;
        const next_delim_pos = std.mem.indexOfPos(u8, body, search_from, delim) orelse return MultipartError.InvalidFormat;
        // The CRLF immediately before the delim belongs to the framing, not the data.
        var data_end = next_delim_pos;
        if (data_end >= 2 and body[data_end - 2] == '\r' and body[data_end - 1] == '\n') {
            data_end -= 2;
        }
        const data = body[search_from..data_end];
        try parts.append(arena, .{
            .name = name.?,
            .filename = filename,
            .content_type = ctype,
            .data = data,
        });
        i = next_delim_pos + delim.len;
    }

    return .{ .parts = try parts.toOwnedSlice(arena) };
}

fn parseContentDisposition(value: []const u8, name_out: *?[]const u8, filename_out: *?[]const u8) void {
    // Expected: form-data; name="field"[; filename="f.txt"]
    var rest = value;
    if (std.mem.indexOfScalar(u8, rest, ';')) |semi| rest = rest[semi + 1 ..];
    while (rest.len > 0) {
        rest = std.mem.trim(u8, rest, " \t;");
        if (rest.len == 0) break;
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse break;
        const key = std.mem.trim(u8, rest[0..eq], " \t");
        var val_start: usize = eq + 1;
        // Quoted or unquoted value.
        if (val_start < rest.len and rest[val_start] == '"') {
            val_start += 1;
            const end = std.mem.indexOfScalarPos(u8, rest, val_start, '"') orelse break;
            const v = rest[val_start..end];
            if (eqlIgnoreCase(key, "name")) name_out.* = v
            else if (eqlIgnoreCase(key, "filename")) filename_out.* = v;
            rest = if (end + 1 < rest.len) rest[end + 1 ..] else "";
        } else {
            const end = std.mem.indexOfScalarPos(u8, rest, val_start, ';') orelse rest.len;
            const v = std.mem.trim(u8, rest[val_start..end], " \t");
            if (eqlIgnoreCase(key, "name")) name_out.* = v
            else if (eqlIgnoreCase(key, "filename")) filename_out.* = v;
            rest = if (end < rest.len) rest[end..] else "";
        }
    }
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

// =========================================================================
// Tests
// =========================================================================

test "boundaryFromContentType extracts boundary" {
    const b = boundaryFromContentType("multipart/form-data; boundary=XYZ").?;
    try std.testing.expectEqualStrings("XYZ", b);
    const c = boundaryFromContentType("multipart/form-data; boundary=\"qu\"").?;
    try std.testing.expectEqualStrings("qu", c);
    try std.testing.expect(boundaryFromContentType("application/json") == null);
}

test "parse one text field" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"hello\"\r\n" ++
        "\r\n" ++
        "world\r\n" ++
        "--B--\r\n";
    const out = try parse(arena, body, "B");
    try std.testing.expectEqual(@as(usize, 1), out.parts.len);
    const p = out.parts[0];
    try std.testing.expectEqualStrings("hello", p.name);
    try std.testing.expectEqualStrings("world", p.data);
    try std.testing.expect(p.filename == null);
}

test "parse text field + file upload" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"user\"\r\n" ++
        "\r\n" ++
        "alice\r\n" ++
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "\x89PNG..." ++ "\r\n" ++
        "--B--\r\n";
    const out = try parse(arena, body, "B");
    try std.testing.expectEqual(@as(usize, 2), out.parts.len);
    try std.testing.expectEqualStrings("alice", out.field("user").?.data);
    const file = out.file("avatar").?;
    try std.testing.expectEqualStrings("a.png", file.filename.?);
    try std.testing.expectEqualStrings("image/png", file.content_type.?);
    try std.testing.expectEqualStrings("\x89PNG...", file.data);
}

test "parse rejects missing boundary" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(MultipartError.BoundaryMissing, parse(arena_state.allocator(), "x", ""));
}

test "parse handles preamble" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        "preamble that browsers shouldn't send but is allowed\r\n" ++
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"k\"\r\n" ++
        "\r\n" ++
        "v\r\n" ++
        "--B--\r\n";
    const out = try parse(arena, body, "B");
    try std.testing.expectEqual(@as(usize, 1), out.parts.len);
    try std.testing.expectEqualStrings("v", out.parts[0].data);
}
