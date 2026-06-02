const std = @import("std");
const am = @import("akamata");
const App = @import("../app.zig").App;
const auth_mw = @import("../auth_mw.zig");

const Ctx = am.Context(App);

pub fn upgrade(ctx: *Ctx) !void {
    if (am.backend != .native) {
        ctx.status(501);
        try ctx.res.text("websocket served by Durable Object on workers");
        return;
    }
    const uid = try auth_mw.requireUser(ctx);

    var conn = try am.ws.upgrade(am.Context(App), ctx, .{ .max_message_bytes = 64 * 1024 });
    defer conn.deinit();

    try ctx.state().hub.attach(uid, &conn);
    defer ctx.state().hub.detach(uid, &conn);

    while (true) {
        const msg = conn.readMessage(ctx.arena) catch return;
        _ = msg; // Mobus clients listen-only; ignore inbound frames.
    }
}
