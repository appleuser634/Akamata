//! Cloudflare Workers adapters. This module is only exposed for the Workers
//! target, keeping JSPI imports out of native binaries.
const std = @import("std");
const queue = @import("../queue.zig");
const events = @import("../events.zig");
const storage = @import("../storage.zig");
const stream = @import("../stream.zig");

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

extern "akamata_r2" fn akamata_r2_put_begin([*]const u8, usize, [*]const u8, usize, [*]const u8, usize) i32;
extern "akamata_r2" fn akamata_r2_put_write(i32, [*]const u8, usize) i32;
extern "akamata_r2" fn akamata_r2_put_finish(i32) i32;
extern "akamata_r2" fn akamata_r2_get_begin([*]const u8, usize, [*]const u8, usize, u64, u64, i32, [*]const u8, usize) i32;
extern "akamata_r2" fn akamata_r2_get_size(i32) u64;
extern "akamata_r2" fn akamata_r2_get_read(i32, [*]u8, usize) i32;
extern "akamata_r2" fn akamata_r2_get_close(i32) void;
extern "akamata_r2" fn akamata_r2_delete([*]const u8, usize, [*]const u8, usize) i32;
extern "akamata_r2" fn akamata_r2_head([*]const u8, usize, [*]const u8, usize) i64;

/// R2-backed portable Store. Reads and writes are chunked through JSPI; the
/// complete object is never materialised in the Zig/WASM heap.
pub const R2Store = struct {
    allocator: std.mem.Allocator,
    binding: []const u8,

    pub fn init(allocator: std.mem.Allocator, binding: []const u8) R2Store {
        return .{ .allocator = allocator, .binding = binding };
    }
    pub fn store(self: *R2Store) storage.Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const ReadState = struct {
        owner: *R2Store,
        handle: i32,
        metadata_buf: [512]u8 = undefined,
        fn read(raw: *anyopaque, out: []u8) stream.Error!usize {
            const self: *ReadState = @ptrCast(@alignCast(raw));
            const n = akamata_r2_get_read(self.handle, out.ptr, out.len);
            if (n < 0) return error.BackendFailure;
            return @intCast(n);
        }
        fn close(raw: *anyopaque) void {
            const self: *ReadState = @ptrCast(@alignCast(raw));
            akamata_r2_get_close(self.handle);
            self.owner.allocator.destroy(self);
        }
    };

    fn put(raw: *anyopaque, key: []const u8, body: stream.Reader, options: storage.PutOptions) storage.Error!storage.Metadata {
        const self: *R2Store = @ptrCast(@alignCast(raw));
        try storage.validateKey(key);
        var option_buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&option_buffer);
        std.json.Stringify.value(options, .{}, &writer) catch return error.BackendFailure;
        const encoded = writer.buffered();
        const handle = akamata_r2_put_begin(self.binding.ptr, self.binding.len, key.ptr, key.len, encoded.ptr, encoded.len);
        if (handle < 0) return mapCode(handle);
        defer body.close();
        var total: u64 = 0;
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const n = body.read(&buffer) catch return error.BackendFailure;
            if (n == 0) break;
            if (akamata_r2_put_write(handle, buffer[0..n].ptr, n) != 0) return error.BackendFailure;
            total += n;
        }
        const rc = akamata_r2_put_finish(handle);
        if (rc != 0) return mapCode(rc);
        return .{ .size = total, .content_type = options.content_type, .custom_json = options.metadata_json };
    }

    fn get(raw: *anyopaque, key: []const u8, options: storage.GetOptions) storage.Error!storage.Object {
        const self: *R2Store = @ptrCast(@alignCast(raw));
        try storage.validateKey(key);
        const state = self.allocator.create(ReadState) catch return error.Unavailable;
        errdefer self.allocator.destroy(state);
        state.* = .{ .owner = self, .handle = -1 };
        var option_buffer: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&option_buffer);
        std.json.Stringify.value(options, .{}, &writer) catch return error.BackendFailure;
        const encoded = writer.buffered();
        const range: storage.Range = options.range orelse .{ .offset = 0, .length = null };
        state.handle = akamata_r2_get_begin(self.binding.ptr, self.binding.len, key.ptr, key.len, range.offset, range.length orelse 0, @intFromBool(options.range != null), encoded.ptr, encoded.len);
        if (state.handle < 0) return mapCode(state.handle);
        return .{
            .metadata = .{ .size = akamata_r2_get_size(state.handle) },
            .body = .{ .ptr = state, .read_fn = ReadState.read, .close_fn = ReadState.close },
        };
    }

    fn delete(raw: *anyopaque, key: []const u8) storage.Error!void {
        const self: *R2Store = @ptrCast(@alignCast(raw));
        try storage.validateKey(key);
        const rc = akamata_r2_delete(self.binding.ptr, self.binding.len, key.ptr, key.len);
        if (rc != 0) return mapCode(rc);
    }
    fn head(raw: *anyopaque, key: []const u8) storage.Error!storage.Metadata {
        const self: *R2Store = @ptrCast(@alignCast(raw));
        try storage.validateKey(key);
        const size = akamata_r2_head(self.binding.ptr, self.binding.len, key.ptr, key.len);
        if (size < 0) return mapCode(@intCast(size));
        return .{ .size = @intCast(size) };
    }
    fn list(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8, _: usize) storage.Error![]storage.ListEntry {
        return error.Unavailable;
    }
    fn mapCode(code: i32) storage.Error {
        return switch (code) {
            -1 => error.NotFound,
            -3 => error.PreconditionFailed,
            -4 => error.PermissionDenied,
            -2 => error.Unavailable,
            else => error.BackendFailure,
        };
    }
    const vtable: storage.Store.VTable = .{ .put = put, .get = get, .delete = delete, .head = head, .list = list };
};
