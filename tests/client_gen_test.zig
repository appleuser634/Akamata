const std = @import("std");
const am = @import("akamata");

const State = struct {};
const CreateUser = struct { name: []const u8, email: []const u8 };
const User = struct { id: i64, name: []const u8, email: []const u8 };

fn dummy(c: *am.Context(State)) !void {
    _ = c;
}

test "client_gen.typescript emits interfaces and functions" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();

    _ = try app.endpoint(.POST, "/users", dummy, am.openapi.Spec(.{
        .request = CreateUser,
        .response = User,
    }));
    _ = try app.endpoint(.GET, "/users/:id", dummy, am.openapi.Spec(.{
        .response = User,
    }));

    const ts = try am.client_gen.generate(@TypeOf(app), &app, alloc, .{
        .target = .typescript,
        .base_url = "http://localhost:8080",
    });
    defer alloc.free(ts);

    try std.testing.expect(std.mem.indexOf(u8, ts, "export interface User") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export interface CreateUser") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "name: string") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "id: number") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "postUsers") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "getUsersById") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "${id}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "JSON.stringify(body)") != null);
}

test "client_gen.zig emits struct stubs" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();

    _ = try app.endpoint(.GET, "/users/:id", dummy, am.openapi.Spec(.{
        .response = User,
    }));

    const code = try am.client_gen.generate(@TypeOf(app), &app, alloc, .{
        .target = .zig,
        .base_url = "http://localhost:8080",
    });
    defer alloc.free(code);

    try std.testing.expect(std.mem.indexOf(u8, code, "pub const User = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "name: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "id: i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub fn getUsersById") != null);
}
