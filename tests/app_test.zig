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

fn failingHandler(_: *am.Context(State)) !void {
    return error.SecretDatabaseFailure;
}

fn requiredInputHandler(c: *am.Context(State)) !void {
    const Input = struct { name: []const u8 };
    _ = (try c.input(Input)) orelse return;
    try c.text("accepted");
}

fn ipHandler(c: *am.Context(State)) !void {
    try c.text(c.req.ip() orelse "none");
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
    try app.dispatchWithPeer(arena, &req, &res, null, null, null);
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
    try app.dispatchWithPeer(arena, &req, &res, null, null, null);
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
    try app.dispatchWithPeer(arena, &req, &res, null, null, null);
    try std.testing.expectEqual(@as(u16, 404), res.status_code);
}

test "basePath registers routes on the parent app" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    var api = try app.basePath("/api/v1");
    _ = try api.get("/hello", helloHandler);
    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();
    var resp = try client.get("/api/v1/hello").send();
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "static routing handles trailing slash and paths over 256 bytes" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/trailing/", helloHandler);
    const long_path = "/" ++ ("x" ** 300);
    _ = try app.get(long_path, helloHandler);
    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();
    var trailing = try client.get("/trailing").send();
    defer trailing.deinit();
    try std.testing.expectEqual(@as(u16, 200), trailing.status);
    var long = try client.get(long_path).send();
    defer long.deinit();
    try std.testing.expectEqual(@as(u16, 200), long.status);
}

test "route registration rejects conflicts and freezes after dispatch" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/same", helloHandler);
    try std.testing.expectError(error.DuplicateRoute, app.get("/same/", helloHandler));
    try std.testing.expectError(error.WildcardMustBeLast, app.get("/files/*rest/more", helloHandler));
    try app.prepare();
    try std.testing.expectError(error.RoutesFrozen, app.get("/late", helloHandler));
    try std.testing.expectError(error.RoutesFrozen, app.useAll(am.mw.logger(State)));
    try std.testing.expectError(error.RoutesFrozen, app.basePath("/late"));
    try std.testing.expectError(error.RoutesFrozen, app.notFound(helloHandler));
}

test "HEAD falls back to GET and unsupported methods return 405 Allow" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/resource", helloHandler);
    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();
    var head = try client.request(.HEAD, "/resource").send();
    defer head.deinit();
    try std.testing.expectEqual(@as(u16, 200), head.status);
    var post = try client.post("/resource").send();
    defer post.deinit();
    try std.testing.expectEqual(@as(u16, 405), post.status);
    try std.testing.expect(post.header("allow") != null);
}

test "default 500 response hides internal error names" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/fail", failingHandler);
    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();
    var resp = try client.get("/fail").send();
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 500), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "SecretDatabaseFailure") == null);
}

test "input treats non-optional fields as required without schema metadata" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.post("/input", requiredInputHandler);
    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();
    var resp = try client.post("/input").body("application/json", "{}").send();
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 422), resp.status);
}

test "client IP ignores forwarding headers unless explicitly trusted" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/ip", ipHandler);
    const headers = [_]am.http.RequestHeader{.{ .name = "x-forwarded-for", .value = "203.0.113.9" }};
    var req: am.Request = .{ .method = .GET, .raw_method = "GET", .path = "/ip", .query = "", .version = "HTTP/1.1", .headers = &headers, .body = "", .keep_alive = false };
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    var res: am.Response = .init(arena_state.allocator());
    try app.dispatchWithPeer(arena_state.allocator(), &req, &res, null, null, "127.0.0.1");
    try std.testing.expectEqualStrings("127.0.0.1", res.body.items);

    const trustLocal = struct {
        fn call(peer: ?[]const u8) bool {
            return peer != null and std.mem.eql(u8, peer.?, "127.0.0.1");
        }
    }.call;
    app.trust_proxy_headers = true;
    app.trusted_proxy_fn = trustLocal;
    var trusted_res: am.Response = .init(arena_state.allocator());
    try app.dispatchWithPeer(arena_state.allocator(), &req, &trusted_res, null, null, "127.0.0.1");
    try std.testing.expectEqualStrings("203.0.113.9", trusted_res.body.items);
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
    try app.dispatchWithPeer(arena, &req, &res, null, null, null);
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
    try app.dispatchWithPeer(arena, &req, &res, null, null, null);

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
    try app.dispatchWithPeer(arena, &req, &res, null, null, null);

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
    try app.dispatchWithPeer(arena, &req, &res, null, null, null);

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
    try app.dispatchWithPeer(arena, &req, &res, null, null, null);

    for (res.headers.items) |h| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "strict-transport-security"));
        try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "content-security-policy"));
    }
}
