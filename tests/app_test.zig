const std = @import("std");
const am = @import("akamata");

const State = struct { hits: std.atomic.Value(u32) = .init(0) };

fn helloHandler(c: *am.Context(State)) !void {
    _ = c.state().hits.fetchAdd(1, .seq_cst);
    try c.json(.{ .greeting = "hi" }, 200);
}

fn paramHandler(c: *am.Context(State)) !void {
    const id = try c.req.param("id");
    try c.json(.{ .id = id }, 200);
}

fn queryHandler(c: *am.Context(State)) !void {
    const q = c.req.query("q") orelse "(none)";
    try c.text(q);
}

test "App routes match and dispatch" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/hello", helloHandler);
    _ = try app.get("/users/:id", paramHandler);
    _ = try app.get("/search", queryHandler);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/hello",
        .query = "",
        .version = "HTTP/1.1",
        .headers = &.{},
        .body = "",
        .keep_alive = false,
    };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);
    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    try std.testing.expect(std.mem.indexOf(u8, res.body.items, "\"greeting\":\"hi\"") != null);
    try std.testing.expectEqual(@as(u32, 1), app.state().hits.load(.seq_cst));
}

test "App resolves :id path parameter" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/users/:id", paramHandler);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/users/42",
        .query = "",
        .version = "HTTP/1.1",
        .headers = &.{},
        .body = "",
        .keep_alive = false,
    };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);
    try std.testing.expect(std.mem.indexOf(u8, res.body.items, "\"id\":\"42\"") != null);
}

test "App returns 404 for unmatched route" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/hello", helloHandler);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/nope",
        .query = "",
        .version = "HTTP/1.1",
        .headers = &.{},
        .body = "",
        .keep_alive = false,
    };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);
    try std.testing.expectEqual(@as(u16, 404), res.status_code);
}

test "Query parameter accessor works" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/search", queryHandler);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/search",
        .query = "q=zig&limit=10",
        .version = "HTTP/1.1",
        .headers = &.{},
        .body = "",
        .keep_alive = false,
    };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);
    try std.testing.expectEqualStrings("zig", res.body.items);
}

test "secureHeaders middleware injects default API-safe headers" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.use("/*", am.mw.secureHeaders(State, .{}));
    _ = try app.get("/hello", helloHandler);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/hello",
        .query = "",
        .version = "HTTP/1.1",
        .headers = &.{},
        .body = "",
        .keep_alive = false,
    };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);

    // Collect header names for inspection.
    var saw_hsts = false;
    var saw_csp = false;
    var saw_xfo = false;
    var saw_xcto = false;
    for (res.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "strict-transport-security")) saw_hsts = true;
        if (std.ascii.eqlIgnoreCase(h.name, "content-security-policy")) saw_csp = true;
        if (std.ascii.eqlIgnoreCase(h.name, "x-frame-options")) saw_xfo = true;
        if (std.ascii.eqlIgnoreCase(h.name, "x-content-type-options")) saw_xcto = true;
    }
    try std.testing.expect(saw_hsts);
    try std.testing.expect(saw_csp);
    try std.testing.expect(saw_xfo);
    try std.testing.expect(saw_xcto);
}

fn bigBodyHandler(c: *am.Context(State)) !void {
    // Predictable, compressible payload bigger than the 1 KB threshold.
    const chunk = "akamata-compression-roundtrip-payload ";
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        try c.res.writeAll(chunk);
    }
}

test "compress middleware gzip-encodes large responses" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.use("/*", am.mw.compress(State, .{}));
    _ = try app.get("/big", bigBodyHandler);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const headers = [_]am.http.RequestHeader{
        .{ .name = "accept-encoding", .value = "gzip, deflate" },
    };
    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/big",
        .query = "",
        .version = "HTTP/1.1",
        .headers = &headers,
        .body = "",
        .keep_alive = false,
    };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);

    var saw_ce_gzip = false;
    for (res.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-encoding") and
            std.mem.eql(u8, h.value, "gzip")) saw_ce_gzip = true;
    }
    try std.testing.expect(saw_ce_gzip);
    // Body must start with the gzip magic.
    try std.testing.expect(res.body.items.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x1f), res.body.items[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), res.body.items[1]);
}

test "compress skips below min_bytes" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.use("/*", am.mw.compress(State, .{}));
    _ = try app.get("/hello", helloHandler);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const headers = [_]am.http.RequestHeader{
        .{ .name = "accept-encoding", .value = "gzip" },
    };
    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/hello",
        .query = "",
        .version = "HTTP/1.1",
        .headers = &headers,
        .body = "",
        .keep_alive = false,
    };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);

    // 18-byte "{"greeting":"hi"}" is well below 1 KB → no compression.
    for (res.headers.items) |h| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "content-encoding"));
    }
}

test "secureHeaders honors per-field opt-out" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.use("/*", am.mw.secureHeaders(State, .{
        .strict_transport_security = null,
        .content_security_policy = null,
    }));
    _ = try app.get("/hello", helloHandler);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/hello",
        .query = "",
        .version = "HTTP/1.1",
        .headers = &.{},
        .body = "",
        .keep_alive = false,
    };
    var res: am.Response = .init(arena);
    try app.dispatch(arena, &req, &res, null, null);

    for (res.headers.items) |h| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "strict-transport-security"));
        try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "content-security-policy"));
    }
}
