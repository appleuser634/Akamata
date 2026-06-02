// Workers entry. Same setup.zig as native; only DATABASE_URL changes.
//
// Default URL on Workers is `d1:DB` (the D1 binding named "DB"). Set
// DATABASE_URL=libsql://… in wrangler.toml `[vars]` if you want Turso instead.

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const setup = @import("setup.zig");

pub const std_options: std.Options = .{ .logFn = noopLog };
fn noopLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}

const wasm_gpa = std.heap.wasm_allocator;

var app_storage: am.App(App) = undefined;
var initialized: bool = false;

fn ensureInit() !void {
    if (initialized) return;
    app_storage = am.App(App).init(wasm_gpa, try setup.buildState(wasm_gpa));
    try setup.registerRoutes(&app_storage);
    initialized = true;
}

export fn akamata_init() void {
    ensureInit() catch return;
    app_storage.serve(.{}) catch {};
}
