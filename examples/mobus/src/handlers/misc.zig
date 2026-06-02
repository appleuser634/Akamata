const std = @import("std");
const am = @import("akamata");
const clock = @import("../clock.zig");
const App = @import("../app.zig").App;
const auth_mw = @import("../auth_mw.zig");
const ids = @import("../ids.zig");

const Ctx = am.Context(App);

pub fn publicPing(ctx: *Ctx) !void {
    try ctx.json(.{ .status = "ok" }, 200);
}

pub fn ping(ctx: *Ctx) !void {
    _ = try auth_mw.requireUser(ctx);
    try ctx.json(.{ .status = "ok" }, 200);
}

pub fn refreshFriendCode(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const new_code = try ids.shortToken(ctx.arena, 8);
    const now = clock.unixSeconds();
    var s = try ctx.state().db.prepare(
        "UPDATE users SET friend_code=?, friend_code_updated_at=?, updated_at=? WHERE id=?",
    );
    defer s.deinit();
    try s.bindAll(.{ new_code, now, now, uid });
    _ = try s.step();
    try ctx.json(.{ .friend_code = new_code }, 200);
}
