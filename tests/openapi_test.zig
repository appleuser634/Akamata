const std = @import("std");
const am = @import("akamata");

const State = struct {};

const CreateUser = struct {
    name: []const u8,
    email: []const u8,
};

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
};

fn createUser(c: *am.Context(State)) !void {
    _ = c;
}

fn getUser(c: *am.Context(State)) !void {
    _ = c;
}

test "openapi.generate produces a spec with documented endpoints" {
    const alloc = std.testing.allocator;
    var app = am.App(State).init(alloc, .{});
    defer app.deinit();

    _ = try app.endpoint(.POST, "/users", createUser, am.openapi.Spec(.{
        .request = CreateUser,
        .response = User,
        .summary = "Create a new user",
        .tags = &.{"users"},
    }));
    _ = try app.endpoint(.GET, "/users/:id", getUser, am.openapi.Spec(.{
        .response = User,
        .summary = "Fetch one user",
        .tags = &.{"users"},
    }));
    // Undocumented route should be omitted.
    _ = try app.get("/health", createUser);

    const spec = try am.openapi.generate(@TypeOf(app), &app, alloc, .{
        .title = "Test",
        .version = "1.0.0",
    });
    defer alloc.free(spec);

    // Sanity: contains both documented paths and their components, omits /health.
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"/users\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"/users/{id}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"#/components/schemas/CreateUser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"#/components/schemas/User\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "Create a new user") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "Fetch one user") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "/health") == null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"openapi\":\"3.1.0\"") != null);
    // Path parameter
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"in\":\"path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"name\":\"id\"") != null);
}
