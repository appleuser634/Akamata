const std = @import("std");
const am = @import("akamata");

const State = struct {};

fn helloHandler(c: *am.Context(State)) !void {
    try c.json(.{ .greeting = "hello, this body is long enough to be ETagged" }, 200);
}

test "etag middleware sets ETag header on the first response" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.use("/*", am.mw.etag(State, .{}));
    _ = try app.get("/hello", helloHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.get("/hello").send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    const tag = resp.header("etag") orelse return error.MissingEtag;
    try std.testing.expect(tag.len > 2);
    try std.testing.expect(tag[0] == '"');
}

test "etag returns 304 when If-None-Match matches" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.use("/*", am.mw.etag(State, .{}));
    _ = try app.get("/hello", helloHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    // First request to collect the ETag.
    var first = try client.get("/hello").send();
    const tag_dup = try alloc.dupe(u8, first.header("etag").?);
    defer alloc.free(tag_dup);
    first.deinit();

    // Second request with matching If-None-Match → 304, empty body.
    var second = try client.get("/hello").header("if-none-match", tag_dup).send();
    defer second.deinit();

    try std.testing.expectEqual(@as(u16, 304), second.status);
    try std.testing.expectEqual(@as(usize, 0), second.body.len);
}

test "etag honors wildcard If-None-Match: *" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();
    _ = try app.use("/*", am.mw.etag(State, .{}));
    _ = try app.get("/hello", helloHandler);

    var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
    defer client.deinit();

    var resp = try client.get("/hello").header("if-none-match", "*").send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 304), resp.status);
}
