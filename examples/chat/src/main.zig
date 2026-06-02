const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const Hub = @import("ws_hub.zig").Hub;
const h = @import("handlers.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var database = try am.db.openSqlite(alloc, "chat.db");
    defer database.close();
    try database.execAll(@embedFile("schema.sql"));

    var hub = Hub.init(alloc);
    defer hub.deinit();

    var app = am.App(App).init(alloc, .{ .db = database, .hub = hub });
    defer app.deinit();

    _ = try app.useAll(am.mw.recover(App));
    _ = try app.useAll(am.mw.logger(App));

    _ = try app.get("/", h.index);
    _ = try app.get("/health", h.health);
    _ = try app.get("/rooms", h.listRooms);
    _ = try app.post("/rooms", h.createRoom);
    _ = try app.get("/rooms/:id/messages", h.listMessages);
    _ = try app.post("/rooms/:id/messages", h.postMessage);
    _ = try app.ws("/rooms/:id/ws", h.wsRoom);

    try app.serve(.{ .port = 8080 });
}
