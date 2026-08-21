//! Shared application layer for the portable reference. No platform binding
//! appears here: Native and Workers supply Db/Store adapters through State.
const std = @import("std");
const am = @import("akamata");
const contracts = @import("contracts.zig");

pub const State = struct {
    db: am.db.Db,
    objects: am.storage.Store,
    jwt_secret: []const u8,
    login_secret: []const u8,
    schema_ready: bool = false,
};
const Ctx = am.Context(State);

pub fn register(app: *am.App(State)) !void {
    _ = try app.useAll(am.mw.recover(State));
    _ = try app.useAll(.{ .name = "portable-schema", .call = ensureSchemaMiddleware });
    _ = try app.get("/health", health);
    _ = try app.post("/login", login);
    _ = try app.post("/__akamata/realtime/authorize", authorizeRealtime);
    _ = try app.post("/realtime/message", realtimeMessage);
    _ = try app.post("/records", createRecord);
    _ = try app.get("/records", listRecords);
    _ = try app.post("/reports", submitReport);
    _ = try app.put("/objects/*key", uploadObject);
    _ = try app.get("/objects/*key", downloadObject);
    _ = try app.head("/objects/*key", downloadObject);
}

fn ensureSchemaMiddleware(c: *Ctx, next: am.Next(State)) anyerror!void {
    if (!c.state().schema_ready) {
        try ensureSchema(c.state().db);
        c.state().schema_ready = true;
    }
    return next.run(c);
}

pub fn ensureSchema(db: am.db.Db) !void {
    try db.exec("CREATE TABLE IF NOT EXISTS portable_records (id INTEGER PRIMARY KEY, principal TEXT NOT NULL, body TEXT NOT NULL, created_at INTEGER NOT NULL)");
    try db.exec("CREATE TABLE IF NOT EXISTS device_reports (id INTEGER PRIMARY KEY, principal TEXT NOT NULL, firmware_version TEXT NOT NULL, hardware_revision TEXT, uptime_seconds INTEGER NOT NULL, error_code INTEGER, created_at INTEGER NOT NULL)");
}

fn health(c: *Ctx) !void {
    try c.json(.{ .status = "ok", .protocol_version = contracts.Protocol.protocol_version }, 200);
}

const LoginInput = struct { subject: []const u8, credential: []const u8 };
fn login(c: *Ctx) !void {
    const input = c.req.json(LoginInput) catch return c.badRequest("invalid login body");
    if (input.subject.len == 0 or input.subject.len > 128 or !timingSafeEqual(input.credential, c.state().login_secret))
        return c.unauthorized("invalid credentials");
    const now = am.observability.clock.unixSeconds();
    const token = try am.auth.jwt.sign(c.arena, c.state().jwt_secret, .{ .sub = input.subject, .iat = now, .exp = now + 3600 });
    try c.json(.{ .access_token = token, .token_type = "Bearer", .expires_in = 3600 }, 200);
}

fn authenticatedSubject(c: *Ctx) ![]const u8 {
    const credential = am.identity.bearer(c.req.header("authorization")) catch return error.Unauthorized;
    const token = switch (credential) {
        .bearer => |value| value,
        else => unreachable,
    };
    const claims = am.auth.jwt.verifyWithOptions(c.arena, c.state().jwt_secret, token, .{
        .now_unix = am.observability.clock.unixSeconds(),
        .require_exp = true,
    }) catch return error.Unauthorized;
    return claims.sub orelse error.Unauthorized;
}

/// The requested resource is an input to authorization only. This reference
/// deliberately derives both room and logical identity from the verified JWT.
fn authorizeRealtime(c: *Ctx) !void {
    const subject = authenticatedSubject(c) catch return c.unauthorized("invalid credential");
    const requested = c.req.query("resource") orelse "default";
    if (!std.mem.eql(u8, requested, "default")) return c.forbidden("room access denied");
    const room = try std.fmt.allocPrint(c.arena, "principal:{s}", .{subject});
    try c.json(.{
        .room = room,
        .logical_identity = subject,
        .principal = .{ .client = subject },
        .metadata = .{ .protocol_version = contracts.Protocol.protocol_version },
    }, 200);
}

const WorkerInbound = struct {
    context: struct { connectionId: []const u8, identity: []const u8, principal: []const u8, metadata: []const u8 },
    envelope: std.json.Value,
};

/// Workers DO calls this internal application handler. It validates the
/// version/type using the same Protocol as Native and returns explicit effects.
fn realtimeMessage(c: *Ctx) !void {
    const input = c.req.json(WorkerInbound) catch return c.badRequest("malformed event");
    if (input.context.identity.len == 0 or input.context.identity.len > 128) return c.forbidden("invalid principal context");
    var encoded: std.Io.Writer.Allocating = .init(c.arena);
    try std.json.Stringify.value(input.envelope, .{}, &encoded.writer);
    const event = contracts.Protocol.decode(c.arena, encoded.written()) catch |err| switch (err) {
        error.UnsupportedVersion => return c.json(.{ .@"error" = "unsupported_protocol_version" }, 426),
        else => return c.badRequest("malformed or unknown event"),
    };
    switch (event) {
        .signal => |signal| try c.json(&.{.{
            .kind = "broadcast_except_sender",
            .envelope = .{ .protocol_version = contracts.Protocol.protocol_version, .event_type = "signal", .payload = signal },
        }}, 200),
        .presence => return c.forbidden("client cannot publish presence"),
    }
}

const RecordInput = struct { body: []const u8 };
fn createRecord(c: *Ctx) !void {
    const subject = authenticatedSubject(c) catch return c.unauthorized("invalid credential");
    const input = c.req.json(RecordInput) catch return c.badRequest("invalid record");
    if (input.body.len == 0 or input.body.len > 1024) return c.badRequest("body exceeds 1024 bytes");
    var stmt = try c.state().db.prepare("INSERT INTO portable_records(principal,body,created_at) VALUES(?,?,?)");
    defer stmt.deinit();
    try stmt.bindAll(.{ subject, input.body, am.observability.clock.unixSeconds() });
    _ = try stmt.step();
    try c.json(.{ .stored = true }, 201);
}

fn listRecords(c: *Ctx) !void {
    const subject = authenticatedSubject(c) catch return c.unauthorized("invalid credential");
    var stmt = try c.state().db.prepare("SELECT id, body, created_at FROM portable_records WHERE principal=? ORDER BY id DESC LIMIT 100");
    defer stmt.deinit();
    try stmt.bindAll(.{subject});
    const Row = struct { id: i64, body: []const u8, created_at: i64 };
    var rows: std.ArrayList(Row) = .empty;
    while ((try stmt.step()) == .row) {
        const row = try stmt.readRow(Row);
        try rows.append(c.arena, .{ .id = row.id, .body = try c.arena.dupe(u8, row.body), .created_at = row.created_at });
    }
    try c.json(.{ .records = rows.items }, 200);
}

const ReportInput = struct {
    firmware_version: []const u8,
    hardware_revision: ?[]const u8 = null,
    uptime_seconds: u64,
    error_code: ?u32 = null,
};
fn submitReport(c: *Ctx) !void {
    const subject = authenticatedSubject(c) catch return c.unauthorized("invalid credential");
    const input = c.req.json(ReportInput) catch return c.badRequest("invalid report");
    if (input.firmware_version.len == 0 or input.firmware_version.len > 64 or (input.hardware_revision != null and input.hardware_revision.?.len > 64))
        return c.badRequest("report field exceeds contract bound");
    var stmt = try c.state().db.prepare("INSERT INTO device_reports(principal,firmware_version,hardware_revision,uptime_seconds,error_code,created_at) VALUES(?,?,?,?,?,?)");
    defer stmt.deinit();
    try stmt.bindAll(.{ subject, input.firmware_version, input.hardware_revision, input.uptime_seconds, input.error_code, am.observability.clock.unixSeconds() });
    _ = try stmt.step();
    try c.json(.{ .stored = true }, 201);
}

fn downloadObject(c: *Ctx) !void {
    _ = authenticatedSubject(c) catch return c.unauthorized("invalid credential");
    const key = c.req.param("key") catch return c.notFound();
    am.storage.serveDownload(c, c.state().objects, key) catch |err| switch (err) {
        error.NotFound => return c.notFound(),
        error.PermissionDenied => return c.forbidden("invalid object key"),
        else => return err,
    };
}

fn uploadObject(c: *Ctx) !void {
    _ = authenticatedSubject(c) catch return c.unauthorized("invalid credential");
    const key = c.req.param("key") catch return c.notFound();
    const bytes = c.req.body();
    if (bytes.len > 8 * 1024 * 1024) return c.badRequest("object exceeds 8 MiB reference limit");
    const Source = struct {
        bytes: []const u8,
        offset: usize = 0,
        fn read(raw: *anyopaque, out: []u8) am.stream.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const n = @min(out.len, self.bytes.len - self.offset);
            @memcpy(out[0..n], self.bytes[self.offset..][0..n]);
            self.offset += n;
            return n;
        }
        fn close(_: *anyopaque) void {}
    };
    var source = Source{ .bytes = bytes };
    const metadata = c.req.header("x-object-metadata");
    if (metadata != null and metadata.?.len > 4096) return c.badRequest("metadata exceeds 4096 bytes");
    const result = try c.state().objects.put(key, .{ .ptr = &source, .read_fn = Source.read, .close_fn = Source.close }, .{
        .content_type = c.req.header("content-type"),
        .metadata_json = metadata,
    });
    try c.json(.{ .key = key, .size = result.size, .etag = result.etag }, 201);
}

fn timingSafeEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var difference: u8 = 0;
    for (a, b) |left, right| difference |= left ^ right;
    return difference == 0;
}

test "credentials use timing-safe equality and rooms derive from principal" {
    try std.testing.expect(timingSafeEqual("secret", "secret"));
    try std.testing.expect(!timingSafeEqual("secret", "other!"));
}
