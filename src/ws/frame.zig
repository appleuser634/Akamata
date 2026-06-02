const std = @import("std");

pub const Opcode = enum(u4) {
    cont = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return (@intFromEnum(self) & 0x8) != 0;
    }
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
};

pub const FrameError = error{
    Incomplete,
    InvalidFrame,
    UnsupportedReservedBits,
    PayloadTooLarge,
    OutOfMemory,
};

/// Decode a single frame from `bytes`. Returns null if more data is needed.
/// On success, `consumed` is the number of bytes read. If the frame was masked,
/// the payload is unmasked in place in a newly allocated slice (so we don't
/// mutate the caller's buffer).
pub fn decode(
    arena: std.mem.Allocator,
    bytes: []const u8,
    max_payload: usize,
) FrameError!?struct { frame: Frame, consumed: usize } {
    if (bytes.len < 2) return null;
    const b0 = bytes[0];
    const b1 = bytes[1];

    const fin = (b0 & 0x80) != 0;
    if ((b0 & 0x70) != 0) return FrameError.UnsupportedReservedBits;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
    const masked = (b1 & 0x80) != 0;
    var pos: usize = 2;
    var payload_len: u64 = @intCast(b1 & 0x7F);

    if (payload_len == 126) {
        if (bytes.len < pos + 2) return null;
        payload_len = std.mem.readInt(u16, bytes[pos..][0..2], .big);
        pos += 2;
    } else if (payload_len == 127) {
        if (bytes.len < pos + 8) return null;
        payload_len = std.mem.readInt(u64, bytes[pos..][0..8], .big);
        pos += 8;
    }

    if (payload_len > max_payload) return FrameError.PayloadTooLarge;

    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (bytes.len < pos + 4) return null;
        @memcpy(&mask, bytes[pos..][0..4]);
        pos += 4;
    }

    const plen: usize = @intCast(payload_len);
    if (bytes.len < pos + plen) return null;

    var payload = try arena.alloc(u8, plen);
    @memcpy(payload, bytes[pos .. pos + plen]);
    if (masked) {
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            payload[i] ^= mask[i & 3];
        }
    }
    return .{
        .frame = .{ .fin = fin, .opcode = opcode, .payload = payload },
        .consumed = pos + plen,
    };
}

/// Encode a server-to-client frame (no masking). Writes into `out` and returns the slice used.
pub fn encode(out: []u8, opcode: Opcode, fin: bool, payload: []const u8) ![]u8 {
    var pos: usize = 0;
    if (out.len < 2) return error.BufferTooSmall;
    out[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));
    pos = 1;
    if (payload.len < 126) {
        out[1] = @intCast(payload.len);
        pos = 2;
    } else if (payload.len <= 0xFFFF) {
        if (out.len < 4) return error.BufferTooSmall;
        out[1] = 126;
        std.mem.writeInt(u16, out[2..][0..2], @intCast(payload.len), .big);
        pos = 4;
    } else {
        if (out.len < 10) return error.BufferTooSmall;
        out[1] = 127;
        std.mem.writeInt(u64, out[2..][0..8], @intCast(payload.len), .big);
        pos = 10;
    }
    if (out.len < pos + payload.len) return error.BufferTooSmall;
    @memcpy(out[pos .. pos + payload.len], payload);
    return out[0 .. pos + payload.len];
}

/// Allocate-and-encode helper.
pub fn encodeAlloc(arena: std.mem.Allocator, opcode: Opcode, fin: bool, payload: []const u8) ![]u8 {
    const cap: usize = payload.len + 14;
    const buf = try arena.alloc(u8, cap);
    return try encode(buf, opcode, fin, payload);
}
