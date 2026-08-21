const std = @import("std");
const am = @import("akamata");
const contracts = @import("contracts.zig");

const State = struct {};
fn health(c: *am.Context(State)) !void {
    try c.json(.{ .status = "ok", .protocol_version = contracts.Protocol.protocol_version }, 200);
}

pub fn main(_: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var app = am.App(State).init(gpa.allocator(), .{});
    defer app.deinit();
    _ = try app.get("/health", health);
    try app.serve(.{ .port = 8080 });
}
