const std = @import("std");
const am = @import("akamata");
const parser = am.http.parser;

test "parses minimal GET request" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = "GET /health HTTP/1.1\r\nhost: localhost\r\n\r\n";
    const p = try parser.parseRequest(arena, bytes, .{});
    try std.testing.expectEqual(am.Method.GET, p.request.method);
    try std.testing.expectEqualStrings("/health", p.request.path);
    try std.testing.expect(p.request.keep_alive);
    try std.testing.expectEqualStrings("localhost", p.request.header("host").?);
}

test "parses POST with content-length body" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "POST /x HTTP/1.1\r\nhost: a\r\ncontent-length: 5\r\n\r\nhello";
    const p = try parser.parseRequest(arena, bytes, .{});
    try std.testing.expectEqual(am.Method.POST, p.request.method);
    try std.testing.expectEqualStrings("hello", p.request.body);
}

test "extracts query string" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "GET /search?q=hi&n=3 HTTP/1.1\r\nhost: a\r\n\r\n";
    const p = try parser.parseRequest(arena, bytes, .{});
    try std.testing.expectEqualStrings("/search", p.request.path);
    try std.testing.expectEqualStrings("q=hi&n=3", p.request.query);
}

test "header lookup is case-insensitive" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "GET / HTTP/1.1\r\nHost: example.test\r\nContent-Type: application/json\r\n\r\n";
    const p = try parser.parseRequest(arena, bytes, .{});
    try std.testing.expectEqualStrings("application/json", p.request.header("content-type").?);
    try std.testing.expectEqualStrings("application/json", p.request.header("CONTENT-TYPE").?);
}

test "returns Incomplete on truncated request" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "GET / HTTP/1.1\r\nhost: a";
    try std.testing.expectError(parser.ParseError.Incomplete, parser.parseRequest(arena, bytes, .{}));
}

test "decodes chunked body" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = "POST /x HTTP/1.1\r\nhost: a\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    const p = try parser.parseRequest(arena, bytes, .{});
    try std.testing.expectEqualStrings("hello world", p.request.body);
}

test "security regression corpus is rejected deterministically" {
    const corpus = [_][]const u8{
        "GET / HTTP/1.1\r\nHost : example\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: +1\r\n\r\nx",
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1, 1\r\n\r\nx",
        "GET / HTTP/1.1\r\nHost: a\r\n\tobs-fold\r\n\r\n",
        "GET / HTTP/1.1\rHost: a\r\r",
        "GET / HTTP/1.1\r\nHost: a\x00b\r\n\r\n",
    };
    for (corpus) |bytes| {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        if (parser.parseRequest(arena_state.allocator(), bytes, .{})) |_| return error.TestExpectedError else |_| {}
    }
}

test "random raw requests never panic or overrun" {
    var prng = std.Random.DefaultPrng.init(0xA6A6_5EC0_2026);
    const random = prng.random();
    var bytes: [2048]u8 = undefined;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var i: usize = 0;
    while (i < 2_000) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        const len = random.intRangeAtMost(usize, 0, bytes.len);
        random.bytes(bytes[0..len]);
        _ = parser.parseRequest(arena_state.allocator(), bytes[0..len], .{ .max_request_bytes = 1024, .max_body_bytes = 1024 }) catch continue;
    }
}
