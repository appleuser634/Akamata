//! HTTP/1.1 Transfer-Encoding: chunked writer.
//!
//! Wraps a downstream `std.Io.Writer` (the socket writer) and frames every
//! flush as a chunk: `<hex-size>\r\n<bytes>\r\n`. Call `end()` exactly once
//! after the last chunk to send the trailing zero-length chunk + the CRLF
//! that terminates the message body.
//!
//! Buffered design: writes <= buffer size are coalesced into a single chunk
//! per flush, which keeps framing overhead bounded for chatty senders (SSE
//! `data: ...\n\n` lines, LLM token-by-token).

const std = @import("std");
const Writer = std.Io.Writer;

pub const ChunkedWriter = struct {
    out: *Writer,
    writer: Writer,
    ended: bool = false,

    pub fn init(downstream: *Writer, buffer: []u8) ChunkedWriter {
        return .{
            .out = downstream,
            .writer = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *ChunkedWriter = @alignCast(@fieldParentPtr("writer", w));

        // Total bytes to frame as one chunk: whatever is already buffered in
        // the chunked writer's own buffer (`w.buffered()`) plus the new data
        // slices, with the final slice repeated `splat` times.
        const buffered = w.buffered();
        var total: usize = buffered.len;
        for (data[0 .. data.len - 1]) |s| total += s.len;
        const tail = data[data.len - 1];
        total += tail.len * splat;

        if (total == 0) {
            // No-op drain. Caller had a zero-sized request and our buffer
            // is empty; nothing to frame. Just consume the buffer.
            w.end = 0;
            return 0;
        }

        // <hex>\r\n
        var hex_buf: [16 + 2]u8 = undefined;
        const hex_str = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{total}) catch
            return Writer.Error.WriteFailed;
        try self.out.writeAll(hex_str);

        // Payload: pre-existing buffered bytes, then each new slice in turn.
        if (buffered.len > 0) try self.out.writeAll(buffered);
        for (data[0 .. data.len - 1]) |s| {
            if (s.len > 0) try self.out.writeAll(s);
        }
        if (tail.len > 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) try self.out.writeAll(tail);
        }

        // Closing CRLF of this chunk.
        try self.out.writeAll("\r\n");

        // Tell the Writer interface what we consumed.
        w.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |s| consumed += s.len;
        consumed += tail.len * splat;
        return consumed;
    }

    /// Force the most-recent chunk all the way down to the FD. Use when
    /// the caller wants the bytes on the wire *now* — long-lived streams
    /// like SSE need this on every event, since the socket writer's own
    /// 4 KB buffer would otherwise hold them until the next flush.
    pub fn flushDownstream(self: *ChunkedWriter) Writer.Error!void {
        try self.writer.flush();
        try self.out.flush();
    }

    /// Flush any buffered data as a final chunk, then write the terminating
    /// `0\r\n\r\n` sequence. Idempotent. Always followed by the caller's own
    /// downstream `flush()` to push bytes to the socket FD.
    pub fn end(self: *ChunkedWriter) Writer.Error!void {
        if (self.ended) return;
        self.ended = true;
        try self.writer.flush();
        try self.out.writeAll("0\r\n\r\n");
    }
};

test "ChunkedWriter frames buffered output and ends with zero chunk" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &sink);
    defer sink = aw.toArrayList();

    var buf: [16]u8 = undefined;
    var cw: ChunkedWriter = .init(&aw.writer, &buf);

    try cw.writer.writeAll("hello");
    try cw.writer.flush();
    try cw.writer.writeAll(", world");
    try cw.writer.flush();
    try cw.end();

    // 5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n
    try std.testing.expectEqualStrings(
        "5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n",
        aw.writer.buffered(),
    );
}

test "ChunkedWriter end() is idempotent" {
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(std.testing.allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &sink);
    defer sink = aw.toArrayList();

    var buf: [16]u8 = undefined;
    var cw: ChunkedWriter = .init(&aw.writer, &buf);
    try cw.writer.writeAll("x");
    try cw.end();
    try cw.end(); // second call is a no-op
    try std.testing.expectEqualStrings("1\r\nx\r\n0\r\n\r\n", aw.writer.buffered());
}
