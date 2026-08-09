const std = @import("std");
const am = @import("akamata");

// Keep these small examples close to the public snippets in README and the
// handler/WebSocket references. This is a compile regression test, not a
// network integration test.
const State = struct {};
const Ctx = am.Context(State);

fn hello(c: *Ctx) !void {
    try c.text("Hello, Akamata!");
}

fn room(c: *Ctx) !void {
    var conn = try am.ws.upgrade(Ctx, c, .{ .max_message_bytes = 64 * 1024 });
    defer conn.deinit();
}

test "documented handler and websocket snippets compile" {
    var app = am.App(State).init(std.testing.allocator, .{});
    defer app.deinit();
    _ = try app.get("/", hello);
    _ = try app.ws("/rooms/:id/ws", room);
}
