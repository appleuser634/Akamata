const std = @import("std");
const am = @import("akamata");

const State = struct {};
var fake_now: i64 = 100;
var store_iface: am.mw.SessionStore = undefined;

fn now() i64 {
    return fake_now;
}

test "invalid response status cannot reach the wire" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var response = am.Response.init(arena_state.allocator());
    response.setStatus(99);
    try std.testing.expectEqual(@as(u16, 500), response.status_code);
    try std.testing.expectError(error.InvalidStatus, response.setStatusChecked(600));
    try response.setStatusChecked(299);
}

fn sessionHandler(c: *am.Context(State)) !void {
    const session = am.mw.currentSession(State, c).?;
    if (try session.get("value")) |value| {
        try c.text(value);
    } else {
        try session.set("value", "present");
        try c.text("new");
    }
}

fn rotateHandler(c: *am.Context(State)) !void {
    const session = am.mw.currentSession(State, c).?;
    try session.rotate(c);
    try c.text("rotated");
}

fn cookieValue(res: *am.Response) ?[]const u8 {
    for (res.headers.items) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "set-cookie")) continue;
        const eq = std.mem.indexOfScalar(u8, header.value, '=') orelse return null;
        const semi = std.mem.indexOfScalarPos(u8, header.value, eq + 1, ';') orelse header.value.len;
        return header.value[eq + 1 .. semi];
    }
    return null;
}

fn dispatch(app: *am.App(State), path: []const u8, cookie: ?[]const u8, arena: std.mem.Allocator) !struct { status: u16, body: []const u8, cookie: ?[]const u8 } {
    const headers: []const am.http.RequestHeader = if (cookie) |value| &.{.{ .name = "cookie", .value = value }} else &.{};
    var req: am.Request = .{ .method = .GET, .raw_method = "GET", .path = path, .query = "", .version = "HTTP/1.1", .headers = headers, .body = "", .keep_alive = false };
    var res = am.Response.init(arena);
    try app.dispatch(arena, &req, &res, null, null);
    return .{ .status = res.status_code, .body = res.body.items, .cookie = cookieValue(&res) };
}

test "session expiry is signed, enforced server-side, and cleaned up" {
    var memory = am.mw.MemorySessionStore.init(std.testing.allocator);
    defer memory.deinit();
    store_iface = memory.store();
    fake_now = 100;
    var app = am.App(State).init(std.testing.allocator, .{});
    defer app.deinit();
    _ = try app.useAll(am.mw.session(State, .{
        .secret = "01234567890123456789012345678901",
        .cookie_max_age_secs = 10,
        .cookie_secure = true,
        .store = &store_iface,
        .now_fn = now,
    }));
    _ = try app.get("/", sessionHandler);
    _ = try app.get("/rotate", rotateHandler);

    var first_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer first_arena.deinit();
    const first = try dispatch(&app, "/", null, first_arena.allocator());
    try std.testing.expectEqualStrings("new", first.body);
    const cookie_header = try std.fmt.allocPrint(first_arena.allocator(), "AKID={s}", .{first.cookie.?});

    var second_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer second_arena.deinit();
    const second = try dispatch(&app, "/", cookie_header, second_arena.allocator());
    try std.testing.expectEqualStrings("present", second.body);

    var rotate_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer rotate_arena.deinit();
    const rotated = try dispatch(&app, "/rotate", cookie_header, rotate_arena.allocator());
    try std.testing.expectEqualStrings("rotated", rotated.body);
    try std.testing.expect(!std.mem.eql(u8, first.cookie.?, rotated.cookie.?));

    fake_now = 110;
    var expired_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer expired_arena.deinit();
    const expired = try dispatch(&app, "/", cookie_header, expired_arena.allocator());
    try std.testing.expectEqualStrings("new", expired.body);
    try std.testing.expect(expired.cookie != null);
}

var rate_now: i64 = 100;
fn rateNow() i64 {
    return rate_now;
}
fn key(c: *am.Context(State)) []const u8 {
    return c.req.header("x-key") orelse "anon";
}
fn ok(c: *am.Context(State)) !void {
    try c.text("ok");
}

fn rateRequest(app: *am.App(State), value: []const u8) !u16 {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var req: am.Request = .{ .method = .GET, .raw_method = "GET", .path = "/", .query = "", .version = "HTTP/1.1", .headers = &.{.{ .name = "x-key", .value = value }}, .body = "", .keep_alive = false };
    var res = am.Response.init(arena_state.allocator());
    try app.dispatch(arena_state.allocator(), &req, &res, null, null);
    return res.status_code;
}

test "rate limiter bounds high-cardinality keys and evicts oldest" {
    rate_now = 100;
    var app = am.App(State).init(std.testing.allocator, .{});
    defer app.deinit();
    _ = try app.useAll(am.mw.rateLimit(State, .{ .key_fn = key, .max_requests = 1, .max_entries = 2, .cleanup_interval = 1, .now_fn = rateNow }));
    _ = try app.get("/", ok);
    try std.testing.expectEqual(@as(u16, 200), try rateRequest(&app, "a"));
    rate_now += 1;
    try std.testing.expectEqual(@as(u16, 200), try rateRequest(&app, "b"));
    rate_now += 1;
    try std.testing.expectEqual(@as(u16, 200), try rateRequest(&app, "c"));
    try std.testing.expectEqual(@as(u16, 200), try rateRequest(&app, "a"));
    try std.testing.expectEqual(@as(u16, 429), try rateRequest(&app, "a"));
}
