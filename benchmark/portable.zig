const std = @import("std");
const am = @import("akamata");

const Signal = struct { session_id: []const u8, value: u8 };
const Event = union(enum) { signal: Signal };
const Protocol = am.events.Protocol(Event, 1);
var delivered: usize = 0;
fn send(_: ?*anyopaque, _: []const u8) am.realtime.Error!void {
    delivered +%= 1;
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const iterations = 100_000;
    var started = am.observability.clock.monotonicNs();
    for (0..iterations) |_| {
        const bytes = try Protocol.encode(allocator, .{ .signal = .{ .session_id = "bench", .value = 1 } }, .{});
        allocator.free(bytes);
    }
    const serialize_ns = am.observability.clock.monotonicNs() - started;
    std.debug.print("typed_event_encode ns/op={d}\n", .{serialize_ns / iterations});

    inline for (.{ 1, 10, 100 }) |count| {
        var native = am.realtime.Native.init(allocator);
        defer native.deinit();
        for (0..count) |i| try native.connect("room", i + 1, null, null, send);
        const room = native.service().room(Protocol, "room");
        started = am.observability.clock.monotonicNs();
        for (0..10_000) |_| _ = try room.broadcast(allocator, .{ .signal = .{ .session_id = "bench", .value = 1 } });
        const elapsed = am.observability.clock.monotonicNs() - started;
        std.debug.print("broadcast connections={d} ns/op={d}\n", .{ count, elapsed / 10_000 });
    }
}
