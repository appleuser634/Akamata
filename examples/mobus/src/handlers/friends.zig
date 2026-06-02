const std = @import("std");
const am = @import("akamata");
const clock = @import("../clock.zig");
const App = @import("../app.zig").App;
const auth_mw = @import("../auth_mw.zig");
const ids = @import("../ids.zig");

const Ctx = am.Context(App);

const RequestBody = struct { receiver_id: []const u8 };
const RespondBody = struct { request_id: []const u8, accept: bool };

pub fn request(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(RequestBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    if (std.mem.eql(u8, uid, body.receiver_id)) {
        return ctx.json(.{ .error_kind = "self_friend_request" }, 400);
    }

    // Check receiver exists.
    {
        var s = try ctx.state().db.prepare("SELECT 1 FROM users WHERE id=?");
        defer s.deinit();
        try s.bindAll(.{body.receiver_id});
        if ((try s.step()) != .row) return ctx.json(.{ .error_kind = "user_not_found" }, 404);
    }

    // Check no existing friend record either direction.
    {
        var s = try ctx.state().db.prepare(
            \\SELECT id FROM friends
            \\ WHERE (requester_id=? AND receiver_id=?)
            \\    OR (requester_id=? AND receiver_id=?)
            \\ LIMIT 1
        );
        defer s.deinit();
        try s.bindAll(.{ uid, body.receiver_id, body.receiver_id, uid });
        if ((try s.step()) == .row) return ctx.json(.{ .error_kind = "already_exists" }, 400);
    }

    const id = try ids.uuidAlloc(ctx.arena);
    const now = clock.unixSeconds();
    var ins = try ctx.state().db.prepare(
        \\INSERT INTO friends(id, requester_id, receiver_id, status, created_at, updated_at)
        \\VALUES(?,?,?, 'pending', ?, ?)
    );
    defer ins.deinit();
    try ins.bindAll(.{ id, uid, body.receiver_id, now, now });
    _ = try ins.step();

    try ctx.json(.{
        .id = id,
        .requester_id = uid,
        .receiver_id = body.receiver_id,
        .status = "pending",
        .created_at = now,
        .updated_at = now,
    }, 201);
}

pub fn respond(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(RespondBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };

    var lookup = try ctx.state().db.prepare(
        "SELECT requester_id, receiver_id, status FROM friends WHERE id=?",
    );
    defer lookup.deinit();
    try lookup.bindAll(.{body.request_id});
    if ((try lookup.step()) != .row) return ctx.json(.{ .error_kind = "not_found" }, 404);
    const Row = struct { requester_id: []const u8, receiver_id: []const u8, status: []const u8 };
    const r = try lookup.readRow(Row);
    const requester = try ctx.arena.dupe(u8, r.requester_id);
    const receiver = try ctx.arena.dupe(u8, r.receiver_id);
    const status = try ctx.arena.dupe(u8, r.status);
    if (!std.mem.eql(u8, receiver, uid)) return ctx.json(.{ .error_kind = "forbidden" }, 403);
    if (!std.mem.eql(u8, status, "pending")) return ctx.json(.{ .error_kind = "not_pending" }, 400);

    const new_status: []const u8 = if (body.accept) "accepted" else "rejected";
    const now = clock.unixSeconds();
    var upd = try ctx.state().db.prepare("UPDATE friends SET status=?, updated_at=? WHERE id=?");
    defer upd.deinit();
    try upd.bindAll(.{ new_status, now, body.request_id });
    _ = try upd.step();

    try ctx.json(.{
        .id = body.request_id,
        .requester_id = requester,
        .receiver_id = receiver,
        .status = new_status,
        .updated_at = now,
    }, 200);
}

pub fn list(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    var s = try ctx.state().db.prepare(
        \\SELECT u.id, u.short_id, u.username, f.created_at FROM friends f
        \\ JOIN users u ON u.id = CASE WHEN f.requester_id=? THEN f.receiver_id ELSE f.requester_id END
        \\ WHERE (f.requester_id=? OR f.receiver_id=?) AND f.status='accepted'
        \\ ORDER BY f.created_at DESC
    );
    defer s.deinit();
    try s.bindAll(.{ uid, uid, uid });

    const Row = struct {
        friend_id: []const u8,
        short_id: []const u8,
        nickname: []const u8,
        created_at: i64,
    };
    var rows: std.ArrayList(Row) = .empty;
    while ((try s.step()) == .row) {
        try rows.append(ctx.arena, .{
            .friend_id = try ctx.arena.dupe(u8, try s.columnText(0)),
            .short_id = try ctx.arena.dupe(u8, try s.columnText(1)),
            .nickname = try ctx.arena.dupe(u8, try s.columnText(2)),
            .created_at = try s.columnInt(3),
        });
    }
    try ctx.json(.{ .friends = rows.items }, 200);
}

pub fn pending(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    var s = try ctx.state().db.prepare(
        \\SELECT f.id, u.id, u.short_id, u.username, f.created_at FROM friends f
        \\ JOIN users u ON u.id = f.requester_id
        \\ WHERE f.receiver_id=? AND f.status='pending'
        \\ ORDER BY f.created_at DESC
    );
    defer s.deinit();
    try s.bindAll(.{uid});
    var rows: std.ArrayList(struct {
        request_id: []const u8,
        requester_id: []const u8,
        short_id: []const u8,
        nickname: []const u8,
        created_at: i64,
    }) = .empty;
    while ((try s.step()) == .row) {
        try rows.append(ctx.arena, .{
            .request_id = try ctx.arena.dupe(u8, try s.columnText(0)),
            .requester_id = try ctx.arena.dupe(u8, try s.columnText(1)),
            .short_id = try ctx.arena.dupe(u8, try s.columnText(2)),
            .nickname = try ctx.arena.dupe(u8, try s.columnText(3)),
            .created_at = try s.columnInt(4),
        });
    }
    try ctx.json(.{ .requests = rows.items }, 200);
}

pub fn history(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    var s = try ctx.state().db.prepare(
        \\SELECT f.id, f.requester_id, f.receiver_id, f.status, f.created_at, f.updated_at
        \\ FROM friends f
        \\ WHERE f.requester_id=? OR f.receiver_id=?
        \\ ORDER BY f.updated_at DESC LIMIT 50
    );
    defer s.deinit();
    try s.bindAll(.{ uid, uid });
    try emitFriendRows(ctx, &s);
}

pub fn rejected(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    var s = try ctx.state().db.prepare(
        \\SELECT f.id, f.requester_id, f.receiver_id, f.status, f.created_at, f.updated_at
        \\ FROM friends f
        \\ WHERE (f.requester_id=? OR f.receiver_id=?) AND f.status='rejected'
        \\ ORDER BY f.updated_at DESC
    );
    defer s.deinit();
    try s.bindAll(.{ uid, uid });
    try emitFriendRows(ctx, &s);
}

fn emitFriendRows(ctx: *Ctx, s: *am.db.Stmt) !void {
    var rows: std.ArrayList(struct {
        request_id: []const u8,
        requester_id: []const u8,
        receiver_id: []const u8,
        status: []const u8,
        created_at: i64,
        updated_at: i64,
    }) = .empty;
    while ((try s.step()) == .row) {
        try rows.append(ctx.arena, .{
            .request_id = try ctx.arena.dupe(u8, try s.columnText(0)),
            .requester_id = try ctx.arena.dupe(u8, try s.columnText(1)),
            .receiver_id = try ctx.arena.dupe(u8, try s.columnText(2)),
            .status = try ctx.arena.dupe(u8, try s.columnText(3)),
            .created_at = try s.columnInt(4),
            .updated_at = try s.columnInt(5),
        });
    }
    try ctx.json(.{ .requests = rows.items }, 200);
}
