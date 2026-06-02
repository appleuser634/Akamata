const std = @import("std");
const am = @import("akamata");
const clock = @import("../clock.zig");
const App = @import("../app.zig").App;
const auth_mw = @import("../auth_mw.zig");
const ids = @import("../ids.zig");

const Ctx = am.Context(App);

const CallBody = struct { receiver_id: []const u8 };
const RespondBody = struct { session_id: []const u8, accept: bool };
const SignalBody = struct { session_id: []const u8, pressed: bool };
const EndBody = struct { session_id: ?[]const u8 = null };

pub fn call(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(CallBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    if (std.mem.eql(u8, uid, body.receiver_id)) return ctx.json(.{ .error_kind = "self_call" }, 400);

    // Ensure no active call exists for either party.
    {
        var s = try ctx.state().db.prepare(
            \\SELECT 1 FROM call_logs WHERE status IN('ringing','active')
            \\ AND (caller_id=? OR receiver_id=? OR caller_id=? OR receiver_id=?) LIMIT 1
        );
        defer s.deinit();
        try s.bindAll(.{ uid, uid, body.receiver_id, body.receiver_id });
        if ((try s.step()) == .row) return ctx.json(.{ .error_kind = "busy" }, 400);
    }

    const id = try ids.uuidAlloc(ctx.arena);
    const session = try ids.uuidAlloc(ctx.arena);
    const now = clock.unixSeconds();
    var ins = try ctx.state().db.prepare(
        \\INSERT INTO call_logs(id, session_id, caller_id, receiver_id, status, started_at)
        \\VALUES(?,?,?,?, 'ringing', ?)
    );
    defer ins.deinit();
    try ins.bindAll(.{ id, session, uid, body.receiver_id, now });
    _ = try ins.step();

    const broadcast = try am.json.allocStringify(ctx.arena, .{
        .kind = "rtchat_incoming",
        .session_id = session,
        .caller_id = uid,
    });
    ctx.state().hub.sendTo(body.receiver_id, broadcast) catch {};

    try ctx.json(.{
        .role = "caller",
        .call = .{ .session_id = session, .status = "ringing", .caller_id = uid, .receiver_id = body.receiver_id, .started_at = now },
    }, 201);
}

pub fn respond(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(RespondBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    var lookup = try ctx.state().db.prepare("SELECT caller_id, receiver_id, status FROM call_logs WHERE session_id=?");
    defer lookup.deinit();
    try lookup.bindAll(.{body.session_id});
    if ((try lookup.step()) != .row) return ctx.json(.{ .error_kind = "not_found" }, 404);
    const caller = try ctx.arena.dupe(u8, try lookup.columnText(0));
    const receiver = try ctx.arena.dupe(u8, try lookup.columnText(1));
    const cur_status = try ctx.arena.dupe(u8, try lookup.columnText(2));
    if (!std.mem.eql(u8, receiver, uid)) return ctx.json(.{ .error_kind = "forbidden" }, 403);
    if (!std.mem.eql(u8, cur_status, "ringing")) return ctx.json(.{ .error_kind = "not_ringing" }, 400);

    const now = clock.unixSeconds();
    const new_status: []const u8 = if (body.accept) "active" else "ended";
    var upd = try ctx.state().db.prepare(
        "UPDATE call_logs SET status=?, accepted_at=?, ended_at=? WHERE session_id=?",
    );
    defer upd.deinit();
    try upd.bind(1, .{ .text = new_status });
    if (body.accept) try upd.bind(2, .{ .int = now }) else try upd.bind(2, .null_value);
    if (body.accept) try upd.bind(3, .null_value) else try upd.bind(3, .{ .int = now });
    try upd.bind(4, .{ .text = body.session_id });
    _ = try upd.step();

    const note = try am.json.allocStringify(ctx.arena, .{
        .kind = if (body.accept) "rtchat_accepted" else "rtchat_rejected",
        .session_id = body.session_id,
    });
    ctx.state().hub.sendTo(caller, note) catch {};

    try ctx.json(.{
        .role = "receiver",
        .accepted = body.accept,
        .call = .{ .session_id = body.session_id, .status = new_status, .caller_id = caller, .receiver_id = receiver },
    }, 200);
}

pub fn end(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(EndBody, ctx.arena, ctx.req.body()) catch EndBody{};

    var sql_buf: [256]u8 = undefined;
    const where = if (body.session_id != null)
        "session_id=? AND status IN('ringing','active')"
    else
        "(caller_id=? OR receiver_id=?) AND status IN('ringing','active') ORDER BY started_at DESC LIMIT 1";
    const sql = try std.fmt.bufPrint(&sql_buf, "SELECT session_id, caller_id, receiver_id FROM call_logs WHERE {s}", .{where});

    var lookup = try ctx.state().db.prepare(sql);
    defer lookup.deinit();
    if (body.session_id) |sid| {
        try lookup.bindAll(.{sid});
    } else {
        try lookup.bindAll(.{ uid, uid });
    }
    if ((try lookup.step()) != .row) return ctx.json(.{ .error_kind = "no_active_call" }, 400);
    const sid = try ctx.arena.dupe(u8, try lookup.columnText(0));
    const caller = try ctx.arena.dupe(u8, try lookup.columnText(1));
    const receiver = try ctx.arena.dupe(u8, try lookup.columnText(2));
    if (!std.mem.eql(u8, caller, uid) and !std.mem.eql(u8, receiver, uid)) {
        return ctx.json(.{ .error_kind = "forbidden" }, 403);
    }

    const now = clock.unixSeconds();
    var upd = try ctx.state().db.prepare("UPDATE call_logs SET status='ended', ended_at=? WHERE session_id=?");
    defer upd.deinit();
    try upd.bindAll(.{ now, sid });
    _ = try upd.step();

    const note = try am.json.allocStringify(ctx.arena, .{ .kind = "rtchat_ended", .session_id = sid });
    const other: []const u8 = if (std.mem.eql(u8, caller, uid)) receiver else caller;
    ctx.state().hub.sendTo(other, note) catch {};

    try ctx.json(.{
        .role = if (std.mem.eql(u8, caller, uid)) "caller" else "receiver",
        .ended = true,
        .call = .{ .session_id = sid, .status = "ended", .caller_id = caller, .receiver_id = receiver },
    }, 200);
}

pub fn signal(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(SignalBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    var lookup = try ctx.state().db.prepare(
        "SELECT caller_id, receiver_id, status FROM call_logs WHERE session_id=?",
    );
    defer lookup.deinit();
    try lookup.bindAll(.{body.session_id});
    if ((try lookup.step()) != .row) return ctx.json(.{ .error_kind = "not_found" }, 404);
    const caller = try ctx.arena.dupe(u8, try lookup.columnText(0));
    const receiver = try ctx.arena.dupe(u8, try lookup.columnText(1));
    const cur_status = try ctx.arena.dupe(u8, try lookup.columnText(2));
    if (!std.mem.eql(u8, cur_status, "active")) return ctx.json(.{ .error_kind = "not_active" }, 400);
    if (!std.mem.eql(u8, caller, uid) and !std.mem.eql(u8, receiver, uid)) {
        return ctx.json(.{ .error_kind = "forbidden" }, 403);
    }

    const other: []const u8 = if (std.mem.eql(u8, caller, uid)) receiver else caller;
    const msg = try am.json.allocStringify(ctx.arena, .{
        .kind = "rtchat_signal",
        .session_id = body.session_id,
        .from = uid,
        .pressed = body.pressed,
    });
    ctx.state().hub.sendTo(other, msg) catch {};

    try ctx.json(.{ .ok = true }, 200);
}

pub fn status(ctx: *Ctx) !void {
    const uid = try auth_mw.requireUser(ctx);
    var s = try ctx.state().db.prepare(
        \\SELECT session_id, caller_id, receiver_id, status, started_at, accepted_at FROM call_logs
        \\ WHERE (caller_id=? OR receiver_id=?) AND status IN('ringing','active')
        \\ ORDER BY started_at DESC LIMIT 1
    );
    defer s.deinit();
    try s.bindAll(.{ uid, uid });
    if ((try s.step()) != .row) return ctx.json(.{ .call = null }, 200);
    const session_id = try ctx.arena.dupe(u8, try s.columnText(0));
    const caller = try ctx.arena.dupe(u8, try s.columnText(1));
    const receiver = try ctx.arena.dupe(u8, try s.columnText(2));
    const st = try ctx.arena.dupe(u8, try s.columnText(3));
    const started = try s.columnInt(4);
    const accepted = try s.columnInt(5);
    const role: []const u8 = if (std.mem.eql(u8, caller, uid)) "caller" else "receiver";
    try ctx.json(.{
        .role = role,
        .call = .{
            .session_id = session_id,
            .caller_id = caller,
            .receiver_id = receiver,
            .status = st,
            .started_at = started,
            .accepted_at = if (accepted == 0) null else accepted,
        },
    }, 200);
}
