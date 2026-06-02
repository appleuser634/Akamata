const std = @import("std");
const am = @import("akamata");
const clock = @import("../clock.zig");
const App = @import("../app.zig").App;
const auth_mw = @import("../auth_mw.zig");
const ids = @import("../ids.zig");

const Ctx = am.Context(App);

const DevicePayload = struct {
    device_type: []const u8,
    device_token: []const u8,
    mqtt_client_id: ?[]const u8 = null,
};

fn isValidType(t: []const u8) bool {
    return std.mem.eql(u8, t, "ios") or std.mem.eql(u8, t, "android") or std.mem.eql(u8, t, "esp32");
}

pub fn create(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(DevicePayload, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    if (!isValidType(body.device_type)) return ctx.json(.{ .error_kind = "invalid_type" }, 400);

    const now = clock.unixSeconds();

    // Upsert by (user_id, device_token)
    var sel = try ctx.state().db.prepare("SELECT id FROM user_devices WHERE user_id=? AND device_token=?");
    defer sel.deinit();
    try sel.bindAll(.{ uid, body.device_token });
    if ((try sel.step()) == .row) {
        const existing_id = try ctx.arena.dupe(u8, try sel.columnText(0));
        var upd = try ctx.state().db.prepare(
            "UPDATE user_devices SET device_type=?, mqtt_client_id=?, updated_at=? WHERE id=?",
        );
        defer upd.deinit();
        if (body.mqtt_client_id) |m| {
            try upd.bindAll(.{ body.device_type, m, now, existing_id });
        } else {
            try upd.bind(1, .{ .text = body.device_type });
            try upd.bind(2, .null_value);
            try upd.bind(3, .{ .int = now });
            try upd.bind(4, .{ .text = existing_id });
        }
        _ = try upd.step();
        try ctx.json(.{
            .id = existing_id,
            .user_id = uid,
            .device_type = body.device_type,
            .device_token = body.device_token,
            .mqtt_client_id = body.mqtt_client_id,
            .updated_at = now,
        }, 200);
        return;
    }

    const id = try ids.uuidAlloc(ctx.arena);
    var ins = try ctx.state().db.prepare(
        \\INSERT INTO user_devices(id, user_id, device_type, device_token, mqtt_client_id, created_at, updated_at)
        \\VALUES(?,?,?,?,?,?,?)
    );
    defer ins.deinit();
    try ins.bind(1, .{ .text = id });
    try ins.bind(2, .{ .text = uid });
    try ins.bind(3, .{ .text = body.device_type });
    try ins.bind(4, .{ .text = body.device_token });
    if (body.mqtt_client_id) |m| try ins.bind(5, .{ .text = m }) else try ins.bind(5, .null_value);
    try ins.bind(6, .{ .int = now });
    try ins.bind(7, .{ .int = now });
    _ = try ins.step();

    try ctx.json(.{
        .id = id,
        .user_id = uid,
        .device_type = body.device_type,
        .device_token = body.device_token,
        .mqtt_client_id = body.mqtt_client_id,
        .created_at = now,
        .updated_at = now,
    }, 201);
}

pub fn list(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    var s = try ctx.state().db.prepare(
        \\SELECT id, device_type, device_token, mqtt_client_id, created_at, updated_at
        \\ FROM user_devices WHERE user_id=? ORDER BY created_at DESC
    );
    defer s.deinit();
    try s.bindAll(.{uid});
    var rows: std.ArrayList(struct {
        id: []const u8,
        device_type: []const u8,
        device_token: []const u8,
        mqtt_client_id: ?[]const u8,
        created_at: i64,
        updated_at: i64,
    }) = .empty;
    while ((try s.step()) == .row) {
        const mq_txt = try s.columnText(3);
        const mq_opt: ?[]const u8 = if (mq_txt.len == 0) null else try ctx.arena.dupe(u8, mq_txt);
        try rows.append(ctx.arena, .{
            .id = try ctx.arena.dupe(u8, try s.columnText(0)),
            .device_type = try ctx.arena.dupe(u8, try s.columnText(1)),
            .device_token = try ctx.arena.dupe(u8, try s.columnText(2)),
            .mqtt_client_id = mq_opt,
            .created_at = try s.columnInt(4),
            .updated_at = try s.columnInt(5),
        });
    }
    try ctx.json(.{ .devices = rows.items }, 200);
}

pub fn update(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const id = ctx.req.paramAs([]const u8, "id") catch return ctx.json(.{ .error_kind = "bad_request" }, 400);
    const body = am.json.parseLeaky(DevicePayload, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    if (!isValidType(body.device_type)) return ctx.json(.{ .error_kind = "invalid_type" }, 400);

    const now = clock.unixSeconds();
    var s = try ctx.state().db.prepare(
        "UPDATE user_devices SET device_type=?, device_token=?, mqtt_client_id=?, updated_at=? WHERE id=? AND user_id=?",
    );
    defer s.deinit();
    try s.bind(1, .{ .text = body.device_type });
    try s.bind(2, .{ .text = body.device_token });
    if (body.mqtt_client_id) |m| try s.bind(3, .{ .text = m }) else try s.bind(3, .null_value);
    try s.bind(4, .{ .int = now });
    try s.bind(5, .{ .text = id });
    try s.bind(6, .{ .text = uid });
    _ = try s.step();
    try ctx.json(.{
        .id = id,
        .device_type = body.device_type,
        .device_token = body.device_token,
        .mqtt_client_id = body.mqtt_client_id,
        .updated_at = now,
    }, 200);
}

pub fn delete(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const id = ctx.req.paramAs([]const u8, "id") catch return ctx.json(.{ .error_kind = "bad_request" }, 400);
    var s = try ctx.state().db.prepare("DELETE FROM user_devices WHERE id=? AND user_id=?");
    defer s.deinit();
    try s.bindAll(.{ id, uid });
    _ = try s.step();
    ctx.status(204);
}
