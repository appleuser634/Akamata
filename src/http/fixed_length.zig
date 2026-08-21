//! Streaming writer for a body whose HTTP Content-Length is known up front.
const std = @import("std");

pub const FixedLengthWriter = struct {
    out: *std.Io.Writer,
    writer: std.Io.Writer,
    expected: u64,
    written: u64 = 0,

    pub fn init(out: *std.Io.Writer, buffer: []u8, expected: u64) FixedLengthWriter {
        return .{ .out = out, .expected = expected, .writer = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FixedLengthWriter = @alignCast(@fieldParentPtr("writer", w));
        const buffered = w.buffered();
        const offered = std.Io.Writer.countSplat(data, splat);
        const total: u64 = buffered.len + offered;
        if (self.written + total > self.expected) return error.WriteFailed;
        if (buffered.len > 0) try self.out.writeAll(buffered);
        for (data[0 .. data.len - 1]) |bytes| try self.out.writeAll(bytes);
        const tail = data[data.len - 1];
        for (0..splat) |_| try self.out.writeAll(tail);
        self.written += total;
        w.end = 0;
        return offered;
    }

    pub fn end(self: *FixedLengthWriter) std.Io.Writer.Error!void {
        try self.writer.flush();
        if (self.written != self.expected) return error.WriteFailed;
        try self.out.flush();
    }
};

test "fixed length writer emits no chunk framing and enforces length" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    var buffer: [4]u8 = undefined;
    var fixed = FixedLengthWriter.init(&sink.writer, &buffer, 5);
    try fixed.writer.writeAll("hello");
    try fixed.end();
    try std.testing.expectEqualStrings("hello", sink.written());

    var overflow = FixedLengthWriter.init(&sink.writer, &buffer, 1);
    try std.testing.expectError(error.WriteFailed, overflow.writer.writeAll("too long"));
}
