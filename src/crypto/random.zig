const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;
extern "akamata_env" fn akamata_random_bytes(buf: [*]u8, len: usize) void;

/// Fill `buf` with OS-backed cryptographic entropy on native targets and the
/// Web Crypto bridge on Workers. This avoids platform-specific libc symbols
/// such as arc4random_buf, which are unavailable on Linux/musl.
pub fn fill(buf: []u8) void {
    if (is_wasm) {
        akamata_random_bytes(buf.ptr, buf.len);
        return;
    }
    var io_impl: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer io_impl.deinit();
    io_impl.io().random(buf);
}
