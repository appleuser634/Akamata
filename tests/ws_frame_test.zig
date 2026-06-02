const std = @import("std");
const am = @import("akamata");
const frame = am.ws.frame;
const handshake = am.ws.handshake;

test "accept key matches RFC example" {
    var out: [64]u8 = undefined;
    const n = try handshake.acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", out[0..n]);
}

test "encode small text frame" {
    var buf: [128]u8 = undefined;
    const out = try frame.encode(&buf, .text, true, "hello");
    try std.testing.expectEqual(@as(usize, 7), out.len);
    try std.testing.expectEqual(@as(u8, 0x81), out[0]);
    try std.testing.expectEqual(@as(u8, 5), out[1]);
    try std.testing.expectEqualStrings("hello", out[2..7]);
}

test "decode unmasked text frame" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    const r = (try frame.decode(arena, &bytes, 1024)).?;
    try std.testing.expect(r.frame.fin);
    try std.testing.expectEqual(frame.Opcode.text, r.frame.opcode);
    try std.testing.expectEqualStrings("hello", r.frame.payload);
    try std.testing.expectEqual(@as(usize, 7), r.consumed);
}

test "decode masked text frame unmasks payload" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mask = [_]u8{ 0x37, 0xfa, 0x21, 0x3d };
    const plain = "hello";
    var masked: [5]u8 = undefined;
    for (plain, 0..) |c, i| masked[i] = c ^ mask[i & 3];
    var bytes: [11]u8 = undefined;
    bytes[0] = 0x81;
    bytes[1] = 0x80 | 5;
    @memcpy(bytes[2..6], &mask);
    @memcpy(bytes[6..11], &masked);
    const r = (try frame.decode(arena, &bytes, 1024)).?;
    try std.testing.expectEqualStrings("hello", r.frame.payload);
}

test "decode returns null on incomplete frame" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = [_]u8{0x81};
    try std.testing.expectEqual(@as(?@TypeOf((try frame.decode(arena, &bytes, 1024)).?), null), try frame.decode(arena, &bytes, 1024));
}

test "encode 126-length frame (extended payload)" {
    var buf: [400]u8 = undefined;
    var payload: [200]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i & 0xff);
    const out = try frame.encode(&buf, .binary, true, &payload);
    try std.testing.expectEqual(@as(usize, 204), out.len);
    try std.testing.expectEqual(@as(u8, 0x82), out[0]);
    try std.testing.expectEqual(@as(u8, 126), out[1]);
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, out[2..4], .big));
}
