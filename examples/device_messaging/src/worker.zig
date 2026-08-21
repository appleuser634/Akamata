const std = @import("std");
const am = @import("akamata");
const application = @import("application.zig");

pub const std_options: std.Options = .{ .logFn = noopLog };
fn noopLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime _: []const u8, _: anytype) void {}
var app: am.App(application.State) = undefined;
var r2: am.platform.workers.R2Store = undefined;
var initialized = false;

fn init() !void {
    if (initialized) return;
    r2 = am.platform.workers.R2Store.init(std.heap.wasm_allocator, "FILES");
    const database = try am.db.openD1(std.heap.wasm_allocator);
    const jwt_secret = am.env.get(std.heap.wasm_allocator, "JWT_SECRET") orelse return error.MissingJwtSecret;
    const login_secret = am.env.get(std.heap.wasm_allocator, "LOGIN_SECRET") orelse return error.MissingLoginSecret;
    app = am.App(application.State).init(std.heap.wasm_allocator, .{
        .db = database,
        .objects = r2.store(),
        .jwt_secret = jwt_secret,
        .login_secret = login_secret,
    });
    try application.register(&app);
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
