// Per-request UUIDv4 ID stamped into `c.user_data` and echoed back as an
// `X-Request-ID` response header. Downstream middlewares (access log,
// metrics) can grab it via `currentRequestId(c)` so a single line of code
// links logs across an outage.

const std = @import("std");
const builtin = @import("builtin");
const app_mod = @import("../app.zig");

const is_wasm = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

extern "c" fn arc4random_buf(buf: [*]u8, n: usize) void;
extern "akamata_env" fn akamata_random_bytes(buf: [*]u8, len: usize) void;

fn fillRandom(buf: []u8) void {
    if (is_wasm) {
        akamata_random_bytes(buf.ptr, buf.len);
    } else {
        arc4random_buf(buf.ptr, buf.len);
    }
}

pub const RequestIdSlot = struct {
    id: [36]u8, // canonical UUIDv4 with dashes
};

pub fn requestId(comptime State: type) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            // If an upstream proxy already set X-Request-ID, honour it
            // (within reason — clip to 64 chars to stop log injection).
            if (c.req.header("x-request-id")) |inbound| {
                if (inbound.len > 0 and inbound.len <= 64 and isPrintable(inbound)) {
                    const slot = try c.arena.create(RequestIdSlot);
                    @memset(&slot.id, 0);
                    const n = @min(inbound.len, slot.id.len);
                    @memcpy(slot.id[0..n], inbound[0..n]);
                    c.user_data = @ptrCast(slot);
                    try c.header("x-request-id", inbound);
                    return next.run(c);
                }
            }
            const slot = try c.arena.create(RequestIdSlot);
            slot.id = mintUuid();
            c.user_data = @ptrCast(slot);
            try c.header("x-request-id", &slot.id);
            return next.run(c);
        }

        fn isPrintable(s: []const u8) bool {
            for (s) |b| if (b < 0x20 or b > 0x7e or b == '"' or b == '\\') return false;
            return true;
        }
    };
    return .{ .name = "requestId", .call = Impl.call };
}

pub fn currentRequestId(comptime State: type, c: *app_mod.App(State).Ctx) ?[]const u8 {
    const p = c.user_data orelse return null;
    const slot: *RequestIdSlot = @ptrCast(@alignCast(p));
    // Strip trailing zeros (in case an upstream ID was shorter than 36 chars).
    var end: usize = slot.id.len;
    while (end > 0 and slot.id[end - 1] == 0) end -= 1;
    return slot.id[0..end];
}

fn mintUuid() [36]u8 {
    var b: [16]u8 = undefined;
    fillRandom(&b);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;

    var out: [36]u8 = undefined;
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
    return out;
}
