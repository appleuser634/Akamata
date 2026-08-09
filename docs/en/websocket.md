# WebSocket

httpz style to upgrade from HTTP route. Do not build a WS-specific listener.

## Handler

```zig
fn wsRoom(ctx: *am.Ctx(App)) !void {
    var conn = try am.ws.upgrade(App, ctx, .{ .max_message_bytes = 64 * 1024 });
    defer conn.deinit();

    while (true) {
        const msg = conn.readMessage(ctx.arena) catch |e| switch (e) {
            am.ws.Conn.ReadError.ClosedByPeer => return,
            else => return e,
        };
        if (msg.opcode == .text) try conn.sendText(msg.payload);
    }
}
```

The route is declared with `R.ws("/path", handler)`. Internally, it is `GET` method + `RouteKind.ws`, but the handler side is explicitly upgraded by calling `am.ws.upgrade()`.

## Broadcast (e.g. chat)

For distribution to multiple WSs, refer to `examples/chat/src/ws_hub.zig`. Room ID → `*Conn` has an array in `std.AutoHashMap` and is protected in `std.Thread.Mutex`.

## Control frame

Inside `Conn.readMessage`:
- `ping` → Automatically reply `pong` with the same payload
- `pong` → ignore
- `close` → `ReadError.ClosedByPeer`

If you want to close it explicitly: `conn.close(1000, "bye")`.

## Workers environment

In Workers, the JS side (`deploy/worker/index.mjs`) detects the WS upgrade and routes it directly to the Durable Object (`ChatRoom`). The WS handler on the Zig side is not called in Workers mode, and the DO side (`deploy/worker/chat_room.mjs`) processes the WS session using JavaScript.
