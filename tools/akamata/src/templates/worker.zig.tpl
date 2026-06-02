// Workers entry. Shares `main.zig`'s `State`, `buildState`, `registerRoutes`,
// and `all_models`. The only Workers-specific concern is the deferred
// migrator: we can't run DDL during `akamata_init` (no JSPI yet), so a
// middleware runs it on the first HTTP request instead.

const std = @import("std");
const am = @import("akamata");
const app_mod = @import("main.zig");
const State = app_mod.State;

pub const std_options: std.Options = .{ .logFn = noopLog };
fn noopLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}

const wasm_gpa = std.heap.wasm_allocator;

var app_storage: am.App(State) = undefined;
var initialized: bool = false;
var migrate_once: am.model.migrate.Once = .{};

fn ensureSchema(c: *am.Context(State), next: am.Next(State)) anyerror!void {
    migrate_once.run(c.arena, c.db(), &app_mod.all_models) catch |e| {
        std.log.warn("deferred migrate failed: {t}", .{e});
    };
    return next.run(c);
}

fn ensureInit() !void {
    if (initialized) return;
    app_storage = am.App(State).init(wasm_gpa, try app_mod.buildState(wasm_gpa));
    _ = try app_storage.useAll(.{ .name = "ensureSchema", .call = ensureSchema });
    try app_mod.registerRoutes(&app_storage);
    initialized = true;
}

export fn akamata_init() void {
    ensureInit() catch return;
    app_storage.serve(.{}) catch {};
}
