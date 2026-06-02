const std = @import("std");
const am = @import("akamata");
const clock = @import("../clock.zig");
const App = @import("../app.zig").App;
const ids = @import("../ids.zig");

const Ctx = am.Context(App);

const token_ttl_secs: i64 = 7 * 24 * 3600;

const RegisterBody = struct {
    login_id: []const u8,
    nickname: []const u8,
    password: []const u8,
};

const LoginBody = struct {
    login_id: []const u8,
    password: []const u8,
};

pub fn register(ctx: *Ctx) !void {
    const body = am.json.parseLeaky(RegisterBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request", .message = "expected {login_id, nickname, password}" }, 400);
    };
    if (body.login_id.len == 0 or body.password.len < 4 or body.nickname.len == 0) {
        return ctx.json(.{ .error_kind = "bad_request", .message = "invalid fields" }, 400);
    }

    // Uniqueness check
    {
        var s = try ctx.state().db.prepare("SELECT 1 FROM users WHERE login_id=?");
        defer s.deinit();
        try s.bindAll(.{body.login_id});
        if ((try s.step()) == .row) {
            return ctx.json(.{ .error_kind = "login_id_taken" }, 400);
        }
    }

    const user_id = try ids.uuidAlloc(ctx.arena);
    const short_id = try ids.shortToken(ctx.arena, 10);
    const friend_code = try ids.shortToken(ctx.arena, 8);
    const now = clock.unixSeconds();
    const password_hash = try am.auth.bcrypt.hash(ctx.arena, body.password, 10);

    var ins = try ctx.state().db.prepare(
        \\INSERT INTO users(id, login_id, username, password_hash, short_id, friend_code,
        \\  friend_code_updated_at, created_at, updated_at)
        \\VALUES(?,?,?,?,?,?,?,?,?)
    );
    defer ins.deinit();
    try ins.bindAll(.{
        user_id, body.login_id, body.nickname, password_hash,
        short_id, friend_code, now, now, now,
    });
    _ = try ins.step();

    const Tok = struct { sub: []const u8, exp: i64, iat: i64 };
    const token = try am.auth.jwt.sign(ctx.arena, ctx.state().cfg.jwt_secret, Tok{
        .sub = user_id,
        .exp = now + token_ttl_secs,
        .iat = now,
    });

    try ctx.json(.{
        .token = token,
        .user_id = user_id,
        .short_id = short_id,
        .friend_code = friend_code,
        .created_at = now,
    }, 201);
}

pub fn login(ctx: *Ctx) !void {
    const body = am.json.parseLeaky(LoginBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };

    var s = try ctx.state().db.prepare("SELECT id, password_hash, short_id, friend_code FROM users WHERE login_id=?");
    defer s.deinit();
    try s.bindAll(.{body.login_id});
    if ((try s.step()) != .row) {
        return ctx.json(.{ .error_kind = "unauthorized" }, 401);
    }
    const Row = struct { id: []const u8, password_hash: []const u8, short_id: []const u8, friend_code: []const u8 };
    const row = try s.readRow(Row);

    // Copy text columns out of the statement-owned buffer before re-using arena.
    const id_copy = try ctx.arena.dupe(u8, row.id);
    const ph_copy = try ctx.arena.dupe(u8, row.password_hash);
    const short_copy = try ctx.arena.dupe(u8, row.short_id);
    const code_copy = try ctx.arena.dupe(u8, row.friend_code);

    am.auth.bcrypt.verify(body.password, ph_copy) catch {
        return ctx.json(.{ .error_kind = "unauthorized" }, 401);
    };

    const now = clock.unixSeconds();
    const Tok = struct { sub: []const u8, exp: i64, iat: i64 };
    const token = try am.auth.jwt.sign(ctx.arena, ctx.state().cfg.jwt_secret, Tok{
        .sub = id_copy,
        .exp = now + token_ttl_secs,
        .iat = now,
    });

    try ctx.json(.{
        .token = token,
        .user_id = id_copy,
        .short_id = short_copy,
        .friend_code = code_copy,
    }, 200);
}

pub fn loginIdAvailable(ctx: *Ctx) !void {
    const login_id = ctx.req.query("login_id") orelse {
        return ctx.json(.{ .error_kind = "bad_request", .message = "missing login_id" }, 400);
    };
    if (login_id.len == 0) {
        return ctx.json(.{ .error_kind = "bad_request", .message = "missing login_id" }, 400);
    }

    var s = try ctx.state().db.prepare("SELECT 1 FROM users WHERE login_id=?");
    defer s.deinit();
    try s.bindAll(.{login_id});
    const available = (try s.step()) == .done;
    try ctx.json(.{ .available = available }, 200);
}
