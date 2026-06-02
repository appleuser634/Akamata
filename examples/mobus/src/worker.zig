const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const setup = @import("setup.zig");

// Workers can't pull in std.Io.Threaded (no posix sockets), and pulling it
// in via the default logger drags it into the binary.
pub const std_options: std.Options = .{ .logFn = noopLog };
fn noopLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}

const wasm_gpa = std.heap.wasm_allocator;

var app_storage: am.App(App) = undefined;
var initialized: bool = false;

fn ensureInit() !void {
    if (initialized) return;
    const state = try setup.buildState(wasm_gpa);
    app_storage = am.App(App).init(wasm_gpa, state);
    try setup.registerRoutes(&app_storage);
    initialized = true;
}

export fn akamata_init() void {
    ensureInit() catch return;
    app_storage.serve(.{}) catch {};
}
