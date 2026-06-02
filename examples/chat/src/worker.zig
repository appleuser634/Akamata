const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const Hub = @import("ws_hub.zig").Hub;
const h = @import("handlers.zig");

pub const std_options: std.Options = .{ .logFn = noopLog };
fn noopLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}

const wasm_gpa = std.heap.wasm_allocator;

var app_storage: am.App(App) = undefined;
var initialized: bool = false;

fn ensureInit() !void {
    if (initialized) return;
    const hub = Hub.init(wasm_gpa);
    app_storage = am.App(App).init(wasm_gpa, .{
        .db = try am.db.openD1(wasm_gpa),
        .hub = hub,
    });
    _ = try app_storage.useAll(am.mw.recover(App));
    _ = try app_storage.get("/", h.index);
    _ = try app_storage.get("/health", h.health);
    _ = try app_storage.get("/rooms", h.listRooms);
    _ = try app_storage.post("/rooms", h.createRoom);
    _ = try app_storage.get("/rooms/:id/messages", h.listMessages);
    _ = try app_storage.post("/rooms/:id/messages", h.postMessage);
    _ = try app_storage.ws("/rooms/:id/ws", h.wsRoom);
    initialized = true;
}

pub fn main() !void {
    try ensureInit();
    try app_storage.serve(.{});
}

export fn akamata_init() void {
    ensureInit() catch return;
    app_storage.serve(.{}) catch {};
}
