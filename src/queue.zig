//! Typed at-least-once queue contract shared by native jobs and Workers Queues.
const std = @import("std");
const events = @import("events.zig");

pub const Delivery = struct {
    event_id: []const u8,
    correlation_id: ?[]const u8 = null,
    idempotency_key: ?[]const u8 = null,
    attempt: u16 = 1,
    max_attempts: u16 = 5,
    failure: ?Failure = null,
    pub const Failure = struct { code: []const u8, message: []const u8 };
};

pub const DeadLetterStrategy = union(enum) { discard, retain, queue: []const u8 };
pub const Error = error{ Unavailable, Rejected, PayloadTooLarge, BackendFailure };

pub const Producer = struct {
    ptr: *anyopaque,
    enqueue_fn: *const fn (*anyopaque, events.EnvelopeMeta, []const u8) Error!void,

    pub fn dispatch(self: Producer, allocator: std.mem.Allocator, comptime Event: type, value: Event, delivery: Delivery) !void {
        const D = events.Descriptor(Event, .{});
        const bytes = try D.encode(allocator, value);
        defer allocator.free(bytes);
        return self.enqueue_fn(self.ptr, .{
            .event_type = D.name,
            .event_id = delivery.event_id,
            .correlation_id = delivery.correlation_id,
            .attempt = delivery.attempt,
        }, bytes);
    }
};

pub fn Consumer(comptime Event: type) type {
    events.validateEventType(Event);
    return struct {
        handler: *const fn (Event, Delivery) anyerror!void,

        pub fn consume(self: @This(), allocator: std.mem.Allocator, bytes: []const u8, delivery: Delivery) !void {
            var parsed = try events.Descriptor(Event, .{}).decode(allocator, bytes);
            defer parsed.deinit();
            return self.handler(parsed.value, delivery);
        }
    };
}

test "typed producer preserves delivery metadata" {
    const Created = struct { id: u64 };
    const Sink = struct {
        calls: usize = 0,
        fn enqueue(ptr: *anyopaque, meta: events.EnvelopeMeta, bytes: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (!std.mem.eql(u8, meta.event_id.?, "evt-1") or bytes.len == 0) return error.BackendFailure;
        }
    };
    var sink: Sink = .{};
    const producer: Producer = .{ .ptr = &sink, .enqueue_fn = Sink.enqueue };
    try producer.dispatch(std.testing.allocator, Created, .{ .id = 1 }, .{ .event_id = "evt-1", .idempotency_key = "record:1" });
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
}
