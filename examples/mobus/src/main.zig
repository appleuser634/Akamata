const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const setup = @import("setup.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const state = try setup.buildState(alloc);
    var app = am.App(App).init(alloc, state);
    defer app.deinit();

    try setup.registerRoutes(&app);

    try app.serve(.{ .port = 8080 });
}
