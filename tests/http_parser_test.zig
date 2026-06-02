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
    const bytes = "GET / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n";
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
