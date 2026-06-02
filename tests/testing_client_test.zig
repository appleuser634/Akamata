const std = @import("std");
const am = @import("akamata");

const State = struct {};

fn helloHandler(c: *am.Context(State)) !void {
    try c.json(.{ .greeting = "hi" }, 200);
}

fn paramHandler(c: *am.Context(State)) !void {
    const id = try c.req.param("id");
    try c.json(.{ .id = id }, 200);
}

fn echoBody(c: *am.Context(State)) !void {
    const Body = struct { name: []const u8 };
    const parsed = try c.req.json(Body);
    try c.json(.{ .echoed = parsed.name }, 200);
}

fn requireAuth(c: *am.Context(State)) !void {
    const auth = c.req.header("authorization") orelse {
        try c.json(.{ .error_kind = "unauthorized" }, 401);
        return;
    };
    try c.json(.{ .ok = true, .auth = auth }, 200);
}

test "test client: simple GET roundtrip" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/hello", helloHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.get("/hello").send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"greeting\":\"hi\"") != null);
}

test "test client: path parameter capture" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/users/:id", paramHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.get("/users/42").send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"42\"") != null);
}

test "test client: JSON body" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.post("/echo", echoBody);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.post("/echo").json(.{ .name = "akamata" }).send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"echoed\":\"akamata\"") != null);
}

test "test client: bearer token" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/me", requireAuth);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    // No token → 401
    {
        var resp = try client.get("/me").send();
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 401), resp.status);
    }
    // With token → 200
    {
        var resp = try client.get("/me").bearer("s3cret").send();
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 200), resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "Bearer s3cret") != null);
    }
}

test "test client: response.json typed parse" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/hello", helloHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.get("/hello").send();
    defer resp.deinit();

    const Greeting = struct { greeting: []const u8 };
    const parsed = try resp.json(Greeting);
    try std.testing.expectEqualStrings("hi", parsed.greeting);
}
