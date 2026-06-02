const std = @import("std");
const builtin = @import("builtin");

const alphabet_short = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // omit confusing 0/O/1/I

const is_wasm = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

const Native = struct {
    extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
};
const Wasm = struct {
    extern "akamata_env" fn akamata_random_bytes(buf: [*]u8, len: usize) void;
};

fn randomBytes(buf: []u8) void {
    if (is_wasm) {
        Wasm.akamata_random_bytes(buf.ptr, buf.len);
        return;
    }
    if (builtin.os.tag == .windows) {
        for (buf) |*b| b.* = 0;
        return;
    }
    Native.arc4random_buf(buf.ptr, buf.len);
}

/// RFC 4122 v4 UUID as 36-char lowercase hex with dashes.
pub fn uuidV4(out: *[36]u8) void {
    var b: [16]u8 = undefined;
    randomBytes(&b);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;
    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[j] = '-';
            j += 1;
        }
        out[j] = hex[b[i] >> 4];
        out[j + 1] = hex[b[i] & 0xF];
        j += 2;
    }
}

pub fn uuidAlloc(arena: std.mem.Allocator) ![]u8 {
    const buf = try arena.alloc(u8, 36);
    uuidV4(buf[0..36]);
    return buf;
}

pub fn shortToken(arena: std.mem.Allocator, len: usize) ![]u8 {
    const buf = try arena.alloc(u8, len);
    const rng_bytes = try arena.alloc(u8, len);
    defer arena.free(rng_bytes);
    randomBytes(rng_bytes);
    for (rng_bytes, 0..) |r, i| {
        buf[i] = alphabet_short[r % alphabet_short.len];
    }
    return buf;
}
