const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;

const Ctx = am.Context(App);

const index_html = @embedFile("index.html");

pub fn index(c: *Ctx) !void {
    c.status(200);
    try c.html(index_html);
}

pub fn health(c: *Ctx) !void {
    try c.json(.{ .status = "ok" }, 200);
}

pub fn listRooms(c: *Ctx) !void {
    const db = c.state().db;
    var stmt = try db.prepare("SELECT id, name, created_at FROM rooms ORDER BY id");
    defer stmt.deinit();

    const Row = struct { id: i64, name: []const u8, created_at: i64 };
    var rows: std.ArrayList(Row) = .empty;

    while ((try stmt.step()) == .row) {
        const r = try stmt.readRow(Row);
        try rows.append(c.arena, .{
            .id = r.id,
            .name = try c.arena.dupe(u8, r.name),
            .created_at = r.created_at,
        });
    }
    try c.json(.{ .rooms = rows.items }, 200);
}

pub fn createRoom(c: *Ctx) !void {
    const Body = struct { name: []const u8 };
    const body = c.req.json(Body) catch {
        return c.json(.{ .error_kind = "bad_request", .message = "expected {name: string}" }, 400);
    };

    var stmt = try c.state().db.prepare("INSERT INTO rooms(name) VALUES(?) RETURNING id, created_at");
    defer stmt.deinit();
    try stmt.bindAll(.{body.name});
    const row = stmt.fetchOne(struct { id: i64, created_at: i64 }) catch {
        return c.json(.{ .error_kind = "conflict", .message = "room already exists" }, 409);
    };
    try c.json(.{ .id = row.id, .name = body.name, .created_at = row.created_at }, 201);
}

pub fn listMessages(c: *Ctx) !void {
    const room_id = c.req.paramAs(i64, "id") catch {
        return c.json(.{ .error_kind = "bad_request" }, 400);
    };

    var stmt = try c.state().db.prepare(
        "SELECT id, user, text, created_at FROM messages WHERE room_id = ? ORDER BY id DESC LIMIT 100",
    );
    defer stmt.deinit();
    try stmt.bindAll(.{room_id});

    const Row = struct { id: i64, user: []const u8, text: []const u8, created_at: i64 };
    var rows: std.ArrayList(Row) = .empty;
    while ((try stmt.step()) == .row) {
        const r = try stmt.readRow(Row);
        try rows.append(c.arena, .{
            .id = r.id,
            .user = try c.arena.dupe(u8, r.user),
            .text = try c.arena.dupe(u8, r.text),
            .created_at = r.created_at,
        });
    }
    try c.json(.{ .messages = rows.items }, 200);
}

pub fn postMessage(c: *Ctx) !void {
    const room_id = c.req.paramAs(i64, "id") catch {
        return c.json(.{ .error_kind = "bad_request" }, 400);
    };
    const Body = struct { user: []const u8, text: []const u8 };
    const body = c.req.json(Body) catch {
        return c.json(.{ .error_kind = "bad_request", .message = "expected {user, text}" }, 400);
    };

    var stmt = try c.state().db.prepare(
        "INSERT INTO messages(room_id, user, text) VALUES(?,?,?) RETURNING id, created_at",
    );
    defer stmt.deinit();
    try stmt.bindAll(.{ room_id, body.user, body.text });
    const row = stmt.fetchOne(struct { id: i64, created_at: i64 }) catch {
        return c.json(.{ .error_kind = "not_found", .message = "room not found" }, 404);
    };

    const out = try am.json.allocStringify(c.arena, .{
        .kind = "message",
        .id = row.id,
        .room_id = room_id,
        .user = body.user,
        .text = body.text,
        .created_at = row.created_at,
    });
    try c.state().hub.broadcast(@intCast(room_id), out);

    try c.json(.{ .id = row.id, .created_at = row.created_at }, 201);
}

pub fn wsRoom(c: *Ctx) !void {
    if (am.backend != .native) {
        return c.json(.{ .error_kind = "ws_via_durable_object" }, 501);
    }
    const room_id = c.req.paramAs(u64, "id") catch {
        return c.json(.{ .error_kind = "bad_request" }, 400);
    };

    var conn = try am.ws.upgrade(Ctx, c, .{ .max_message_bytes = 64 * 1024 });
    defer conn.deinit();

    try c.state().hub.attach(room_id, &conn);
    defer c.state().hub.detach(room_id, &conn);

    while (true) {
        const msg = conn.readMessage(c.arena) catch |e| switch (e) {
            error.ClosedByPeer => return,
            else => return e,
        };
        if (msg.opcode == .text) {
            try c.state().hub.broadcast(room_id, msg.payload);
        }
    }
}
