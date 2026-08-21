//! Cloudflare Workers adapters. This module is only exposed for the Workers
//! target, keeping JSPI imports out of native binaries.
const std = @import("std");
const queue = @import("../queue.zig");
const events = @import("../events.zig");

extern "akamata_queue" fn akamata_queue_send(
    binding_ptr: [*]const u8,
    binding_len: usize,
    meta_ptr: [*]const u8,
    meta_len: usize,
    payload_ptr: [*]const u8,
    payload_len: usize,
) i32;

pub const QueueProducer = struct {
    binding: []const u8,

    pub fn producer(self: *QueueProducer) queue.Producer {
        return .{ .ptr = self, .enqueue_fn = enqueue };
    }

    fn enqueue(ptr: *anyopaque, meta: events.EnvelopeMeta, payload: []const u8) queue.Error!void {
        const self: *QueueProducer = @ptrCast(@alignCast(ptr));
        var buffer: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        std.json.Stringify.value(meta, .{}, &writer) catch return error.BackendFailure;
        const encoded = writer.buffered();
        return switch (akamata_queue_send(self.binding.ptr, self.binding.len, encoded.ptr, encoded.len, payload.ptr, payload.len)) {
            0 => {},
            -2 => error.Unavailable,
            -3 => error.PayloadTooLarge,
            else => error.BackendFailure,
        };
    }
};

/// Install a raw queue consumer at application startup. Typed consumers can
/// decode the versioned envelope and delegate to `queue.Consumer(T)`.
pub fn setQueueConsumer(handler: @import("../runtime/workers.zig").QueueFn) void {
    @import("../runtime/workers.zig").setQueueDispatch(handler);
}
