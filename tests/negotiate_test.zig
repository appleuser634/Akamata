const std = @import("std");
const am = @import("akamata");

const State = struct {};

fn dualHandler(c: *am.Context(State)) !void {
    const mt = c.negotiate(&.{ "application/json", "text/html" }) orelse {
        try c.json(.{ .error_kind = "not_acceptable" }, 406);
        return;
    };
    if (std.mem.eql(u8, mt, "text/html")) {
        try c.html("<h1>hi</h1>");
    } else {
        try c.json(.{ .greeting = "hi" }, 200);
    }
}

test "ctx.negotiate picks JSON for Accept: application/json" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/greet", dualHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.get("/greet").header("accept", "application/json").send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"greeting\":\"hi\"") != null);
}

test "ctx.negotiate picks HTML when client prefers text/*" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/greet", dualHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.get("/greet").header("accept", "text/*").send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "<h1>hi</h1>") != null);
}

test "ctx.negotiate returns 406 when no candidate matches" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.get("/greet", dualHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.get("/greet").header("accept", "image/jpeg").send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 406), resp.status);
}
