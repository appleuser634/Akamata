const std = @import("std");
const am = @import("akamata");
const clock = @import("../clock.zig");
const App = @import("../app.zig").App;
const auth_mw = @import("../auth_mw.zig");
const ids = @import("../ids.zig");

const Ctx = am.Context(App);

const SendBody = struct { receiver_id: []const u8, content: []const u8 };

fn isFriend(ctx: *Ctx, a: []const u8, b: []const u8) !bool {
    var s = try ctx.state().db.prepare(
        \\SELECT 1 FROM friends WHERE status='accepted' AND
        \\  ((requester_id=? AND receiver_id=?) OR (requester_id=? AND receiver_id=?))
    );
    defer s.deinit();
    try s.bindAll(.{ a, b, b, a });
    return (try s.step()) == .row;
}

pub fn send(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(SendBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    if (body.content.len == 0) return ctx.json(.{ .error_kind = "empty_content" }, 400);
    if (!try isFriend(ctx, uid, body.receiver_id)) {
        return ctx.json(.{ .error_kind = "not_friends" }, 400);
    }

    const id = try ids.uuidAlloc(ctx.arena);
    const now = clock.unixSeconds();
    var ins = try ctx.state().db.prepare(
        \\INSERT INTO messages(id, sender_id, receiver_id, content, is_read, created_at)
        \\VALUES(?,?,?,?,0,?)
    );
    defer ins.deinit();
    try ins.bindAll(.{ id, uid, body.receiver_id, body.content, now });
    _ = try ins.step();

    // Broadcast to receiver via WS hub.
    const broadcast = try am.json.allocStringify(ctx.arena, .{
        .kind = "message",
        .id = id,
        .sender_id = uid,
        .receiver_id = body.receiver_id,
        .content = body.content,
        .is_read = false,
        .created_at = now,
    });
    ctx.state().hub.sendTo(body.receiver_id, broadcast) catch {};

    // MQTT publish (best effort, native only)
    if (am.backend == .native and ctx.state().cfg.mqtt_broker.len > 0) {
        var pubr = am.mq.Publisher.init(ctx.arena, .{
            .broker = ctx.state().cfg.mqtt_broker,
            .client_id = ctx.state().cfg.mqtt_client_id,
            .username = ctx.state().cfg.mqtt_username,
            .password = ctx.state().cfg.mqtt_password,
        });
        const topic = try std.fmt.allocPrint(ctx.arena, "chat/messages/{s}", .{body.receiver_id});
        pubr.publish(topic, broadcast) catch {};
    }

    // FCM push (best effort)
    sendFcmToReceiver(ctx, body.receiver_id, body.content) catch {};

    try ctx.json(.{
        .id = id,
        .sender_id = uid,
        .receiver_id = body.receiver_id,
        .content = body.content,
        .is_read = false,
        .created_at = now,
    }, 201);
}

fn sendFcmToReceiver(ctx: *Ctx, receiver_id: []const u8, content: []const u8) !void {
    if (ctx.state().cfg.fcm_service_account_path == null) return;
    var s = try ctx.state().db.prepare("SELECT device_token FROM user_devices WHERE user_id=? AND device_type IN('ios','android')");
    defer s.deinit();
    try s.bindAll(.{receiver_id});
    while ((try s.step()) == .row) {
        const token = try ctx.arena.dupe(u8, try s.columnText(0));
        ctx.state().push.send(token, .{ .title = "新着メッセージ", .body = content }) catch {};
    }
}

pub fn unreadCount(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    var s = try ctx.state().db.prepare("SELECT COUNT(*) FROM messages WHERE receiver_id=? AND is_read=0");
    defer s.deinit();
    try s.bindAll(.{uid});
    _ = try s.step();
    const c = try s.columnInt(0);
    try ctx.json(.{ .count = c }, 200);
}

pub fn listWithFriend(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const friend = ctx.req.paramAs([]const u8, "id") catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    if (!try isFriend(ctx, uid, friend)) {
        return ctx.json(.{ .error_kind = "not_friends" }, 400);
    }
    var s = try ctx.state().db.prepare(
        \\SELECT id, sender_id, receiver_id, content, is_read, created_at FROM messages
        \\ WHERE (sender_id=? AND receiver_id=?) OR (sender_id=? AND receiver_id=?)
        \\ ORDER BY created_at DESC LIMIT 50
    );
    defer s.deinit();
    try s.bindAll(.{ uid, friend, friend, uid });

    var rows: std.ArrayList(struct {
        id: []const u8,
        sender_id: []const u8,
        receiver_id: []const u8,
        content: []const u8,
        is_read: bool,
        created_at: i64,
    }) = .empty;
    while ((try s.step()) == .row) {
        try rows.append(ctx.arena, .{
            .id = try ctx.arena.dupe(u8, try s.columnText(0)),
            .sender_id = try ctx.arena.dupe(u8, try s.columnText(1)),
            .receiver_id = try ctx.arena.dupe(u8, try s.columnText(2)),
            .content = try ctx.arena.dupe(u8, try s.columnText(3)),
            .is_read = (try s.columnInt(4)) != 0,
            .created_at = try s.columnInt(5),
        });
    }
    try ctx.json(.{ .messages = rows.items }, 200);
}

pub fn markRead(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const mid = ctx.req.paramAs([]const u8, "id") catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    var s = try ctx.state().db.prepare("UPDATE messages SET is_read=1 WHERE id=? AND receiver_id=?");
    defer s.deinit();
    try s.bindAll(.{ mid, uid });
    _ = try s.step();
    ctx.status(200);
}

pub fn markAllReadFromFriend(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const friend = ctx.req.paramAs([]const u8, "id") catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    var s = try ctx.state().db.prepare(
        "UPDATE messages SET is_read=1 WHERE sender_id=? AND receiver_id=? AND is_read=0",
    );
    defer s.deinit();
    try s.bindAll(.{ friend, uid });
    _ = try s.step();
    // SQLite's affected-rows count is not exposed via our vtable yet; report 0 for now.
    try ctx.json(.{ .count = 0 }, 200);
}
