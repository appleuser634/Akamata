const std = @import("std");
const am = @import("akamata");

const State = struct { db: am.db.Db };

fn observed(c: *am.Context(State)) !void {
    try std.testing.expectEqualStrings("/items/:id", c.routePattern().?);
    try std.testing.expect(c.requestId() != null);
    var custom = c.startSpan("r2.put");
    defer custom.end();
    var stmt = try c.db().prepare("SELECT value FROM items WHERE id = ?");
    defer stmt.deinit();
    try stmt.bind(1, .{ .int = 1 });
    _ = try stmt.step();
    _ = try stmt.columnText(0);
    try c.text("ok");
}

test "request id, route template, DB timing, span, metrics and Server-Timing" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT)");
    try db.exec("INSERT INTO items(id, value) VALUES (1, 'one')");

    var counters: am.mw.MetricsCounters = .{};
    var app = am.App(State).init(alloc, .{ .db = db });
    defer app.deinit();
    _ = try app.useAll(am.mw.requestId(State));
    _ = try app.useAll(am.mw.metricsWithConfig(State, &counters, .{ .latency_profile = .web }));
    _ = try app.useAll(am.mw.serverTiming(State, .{ .enabled = true }));
    _ = try app.get("/items/:id", observed);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var req: am.Request = .{ .method = .GET, .raw_method = "GET", .path = "/items/1", .query = "", .version = "HTTP/1.1", .headers = &.{}, .body = "", .keep_alive = false };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);

    try std.testing.expectEqualStrings("ok", res.body.items);
    try std.testing.expectEqual(@as(u64, 1), counters.requests_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), counters.db_operations[@intFromEnum(am.observability.Backend.sqlite)].load(.monotonic));
    var saw_request_id = false;
    var saw_timing = false;
    for (res.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "x-request-id")) saw_request_id = true;
        if (std.ascii.eqlIgnoreCase(h.name, "server-timing")) {
            saw_timing = std.mem.indexOf(u8, h.value, "db;dur=") != null and std.mem.indexOf(u8, h.value, "r2.put;dur=") != null;
        }
    }
    try std.testing.expect(saw_request_id);
    try std.testing.expect(saw_timing);
}

test "disabled Server-Timing emits no header" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    var app = am.App(State).init(alloc, .{ .db = db });
    defer app.deinit();
    _ = try app.useAll(am.mw.serverTiming(State, .{}));
    const H = struct {
        fn call(c: *am.Context(State)) !void {
            try c.text("ok");
        }
    };
    _ = try app.get("/items/:id", H.call);
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var req: am.Request = .{ .method = .GET, .raw_method = "GET", .path = "/items/1", .query = "", .version = "HTTP/1.1", .headers = &.{}, .body = "", .keep_alive = false };
    var res: am.Response = .init(arena);
    app.dispatch(arena, &req, &res, null, null) catch {};
    for (res.headers.items) |h| try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "server-timing"));
}
