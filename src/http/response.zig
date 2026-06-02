const std = @import("std");
const status = @import("status.zig");
const ChunkedWriter = @import("chunked.zig").ChunkedWriter;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HeaderError = error{
    /// Header name contained a character outside the RFC 9110 token set,
    /// or value contained CR/LF/NUL (response-splitting / CRLF injection).
    InvalidHeader,
};

pub const StreamError = error{
    /// startStream() called twice, or called after the response had already
    /// committed buffered body bytes.
    AlreadyStreaming,
    /// Streaming is not supported on this build target. Workers currently
    /// requires its own ReadableStream bridge — falling back here would
    /// silently produce truncated responses, so we fail loudly instead.
    UnsupportedOnTarget,
};

pub const StreamOptions = struct {
    /// Headers can still be added after `startStream` returns, but they
    /// will not be honored — the status line + headers have already been
    /// flushed. Set them on `res` before calling `startStream`.
    /// content-type defaults to "application/octet-stream" if not set.
    content_type: ?[]const u8 = null,
};

/// RFC 9110 §5.6.2 — token chars: `! # $ % & ' * + - . ^ _ ` | ~` + alnum.
fn isHeaderNameByte(ch: u8) bool {
    return switch (ch) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'a'...'z', 'A'...'Z' => true,
        else => false,
    };
}

fn validateHeaderName(name: []const u8) HeaderError!void {
    if (name.len == 0) return HeaderError.InvalidHeader;
    for (name) |b| if (!isHeaderNameByte(b)) return HeaderError.InvalidHeader;
}

fn validateHeaderValue(value: []const u8) HeaderError!void {
    // Per RFC 9110 §5.5 header field values must not contain CR, LF, or NUL.
    // We are intentionally strict here — `value\r\nInjected: x` is the
    // canonical response-splitting payload.
    for (value) |b| {
        if (b == '\r' or b == '\n' or b == 0) return HeaderError.InvalidHeader;
    }
}

/// Response is built in memory by default, then flushed to the connection
/// writer at the end. Handlers can switch to streaming mode by calling
/// `startStream` — the status line + headers flush immediately and the
/// returned writer frames every write as an HTTP/1.1 chunk.
pub const Response = struct {
    arena: std.mem.Allocator,
    status_code: u16 = 200,
    headers: std.ArrayList(Header) = .empty,
    body: std.ArrayList(u8) = .empty,
    finalized: bool = false,
    keep_alive: bool = true,
    is_upgrade: bool = false,

    /// Set by the server right before invoking the handler chain. Streaming
    /// uses this to push chunked frames directly to the socket. Stays null
    /// in test contexts (where `app.dispatch` writes through a buffer).
    socket_writer: ?*std.Io.Writer = null,
    /// Once non-null, the response has committed to chunked streaming;
    /// `writeTo` becomes a no-op (the server only calls `endStream`).
    streaming: ?*ChunkedWriter = null,

    pub fn init(arena: std.mem.Allocator) Response {
        return .{ .arena = arena };
    }

    /// Switch to streaming mode. Writes the status line + headers + the
    /// `transfer-encoding: chunked` framing prelude immediately, then
    /// returns a `*std.Io.Writer` whose every `flush()` sends one chunk.
    ///
    /// Streaming responses cannot keep-alive — the response length is
    /// only known to the handler, and pipelining a follow-up request on
    /// the same connection would race with the chunked terminator.
    pub fn startStream(self: *Response, opts: StreamOptions) !*std.Io.Writer {
        if (self.streaming != null) return StreamError.AlreadyStreaming;
        if (self.body.items.len > 0) return StreamError.AlreadyStreaming;
        const sw = self.socket_writer orelse return StreamError.UnsupportedOnTarget;

        self.keep_alive = false;

        // Ensure transfer-encoding: chunked and (optionally) content-type
        // are set, but only if the caller didn't pre-set them.
        var saw_te = false;
        var saw_ct = false;
        for (self.headers.items) |h| {
            if (eqlIgnoreCase(h.name, "transfer-encoding")) saw_te = true;
            if (eqlIgnoreCase(h.name, "content-type")) saw_ct = true;
        }
        if (!saw_te) try self.header("transfer-encoding", "chunked");
        if (!saw_ct) {
            const ct = opts.content_type orelse "application/octet-stream";
            try self.header("content-type", ct);
        }

        // Flush status line + headers. We push them all the way to the FD
        // so the client immediately sees a 200 + headers; otherwise an
        // EventSource would sit in "Connecting…" until the first chunk
        // landed (or 4 KB of header lines had piled up in the buffer).
        const code: status.Code = @enumFromInt(self.status_code);
        try sw.print("HTTP/1.1 {d} {s}\r\n", .{ self.status_code, code.phrase() });
        for (self.headers.items) |h| try sw.print("{s}: {s}\r\n", .{ h.name, h.value });
        try sw.print("connection: close\r\n", .{});
        try sw.writeAll("\r\n");
        try sw.flush();

        // Allocate the ChunkedWriter + its buffer in the per-request arena.
        const cw_buf = try self.arena.alloc(u8, 8 * 1024);
        const cw = try self.arena.create(ChunkedWriter);
        cw.* = ChunkedWriter.init(sw, cw_buf);
        self.streaming = cw;
        return &cw.writer;
    }

    /// Finalize a streaming response. Idempotent. Called by the server
    /// after the handler returns; handlers don't need to call this.
    pub fn endStream(self: *Response) !void {
        const cw = self.streaming orelse return;
        try cw.end();
    }

    pub fn setStatus(self: *Response, code: u16) void {
        self.status_code = code;
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        try validateHeaderName(name);
        try validateHeaderValue(value);
        try self.headers.append(self.arena, .{ .name = name, .value = value });
    }

    pub fn setHeaderFmt(self: *Response, name: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try validateHeaderName(name);
        const v = try std.fmt.allocPrint(self.arena, fmt, args);
        try validateHeaderValue(v);
        try self.headers.append(self.arena, .{ .name = name, .value = v });
    }

    pub fn text(self: *Response, body: []const u8) !void {
        try self.header("content-type", "text/plain; charset=utf-8");
        try self.body.appendSlice(self.arena, body);
    }

    pub fn html(self: *Response, body: []const u8) !void {
        try self.header("content-type", "text/html; charset=utf-8");
        try self.body.appendSlice(self.arena, body);
    }

    pub fn json(self: *Response, value: anytype) !void {
        try self.header("content-type", "application/json");
        var alloc_w: std.Io.Writer.Allocating = .fromArrayList(self.arena, &self.body);
        defer self.body = alloc_w.toArrayList();
        // PERF9: comptime-specialised emitter for known shapes; falls back
        // to std.json.Stringify.value otherwise.
        try @import("../json.zig").appendValue(@TypeOf(value), value, &alloc_w.writer);
    }

    pub fn writeAll(self: *Response, bytes: []const u8) !void {
        try self.body.appendSlice(self.arena, bytes);
    }

    /// Write the full HTTP response to `w`. Caller is responsible for flushing.
    /// No-op when streaming: the status line + headers + chunks have already
    /// been written directly to the socket.
    pub fn writeTo(self: *Response, w: anytype) !void {
        if (self.streaming != null) return;
        const code: status.Code = @enumFromInt(self.status_code);
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status_code, code.phrase() });

        var saw_content_length = false;
        var saw_connection = false;
        for (self.headers.items) |h| {
            if (eqlIgnoreCase(h.name, "content-length")) saw_content_length = true;
            if (eqlIgnoreCase(h.name, "connection")) saw_connection = true;
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }

        if (!self.is_upgrade) {
            if (!saw_content_length) {
                try w.print("content-length: {d}\r\n", .{self.body.items.len});
            }
            if (!saw_connection) {
                const conn_value: []const u8 = if (self.keep_alive) "keep-alive" else "close";
                try w.print("connection: {s}\r\n", .{conn_value});
            }
        }
        try w.writeAll("\r\n");
        if (self.body.items.len > 0) try w.writeAll(self.body.items);
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

test "header() rejects CRLF in value (response splitting)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var res = Response.init(arena_state.allocator());
    try std.testing.expectError(HeaderError.InvalidHeader, res.header("location", "/x\r\nInjected: 1"));
}

test "header() rejects NUL in value" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var res = Response.init(arena_state.allocator());
    try std.testing.expectError(HeaderError.InvalidHeader, res.header("x-trace", "abc\x00def"));
}

test "header() rejects non-token header name" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var res = Response.init(arena_state.allocator());
    try std.testing.expectError(HeaderError.InvalidHeader, res.header("x trace", "ok"));
    try std.testing.expectError(HeaderError.InvalidHeader, res.header("x:trace", "ok"));
    try std.testing.expectError(HeaderError.InvalidHeader, res.header("", "ok"));
}
