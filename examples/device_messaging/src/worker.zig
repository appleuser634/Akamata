const std = @import("std");
const am = @import("akamata");
const contracts = @import("contracts.zig");

pub const std_options: std.Options = .{ .logFn = noopLog };
fn noopLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}
const State = struct { objects: am.storage.Store };
var app: am.App(State) = undefined;
var r2: am.platform.workers.R2Store = undefined;
var initialized = false;

fn health(c: *am.Context(State)) !void {
    try c.json(.{ .status = "ok", .protocol_version = contracts.Protocol.protocol_version }, 200);
}
fn init() !void {
    if (initialized) return;
    r2 = am.platform.workers.R2Store.init(std.heap.wasm_allocator, "FILES");
    app = am.App(State).init(std.heap.wasm_allocator, .{ .objects = r2.store() });
    _ = try app.get("/health", health);
    initialized = true;
}
pub fn main() !void {
    try init();
    try app.serve(.{});
}
export fn akamata_init() void {
    init() catch return;
    app.serve(.{}) catch {};
}
