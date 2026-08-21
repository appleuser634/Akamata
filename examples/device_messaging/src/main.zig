const std = @import("std");
const am = @import("akamata");
const application = @import("application.zig");

pub fn main(_: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, ".akamata-device-objects") catch {};
    var root = try std.Io.Dir.cwd().openDir(io, ".akamata-device-objects", .{ .iterate = true });
    defer root.close(io);
    var files = am.storage.filesystem.FileStore.init(allocator, io, root);
    const database = try am.db.openSqlite(allocator, "device_messaging.db");
    defer database.close();
    try application.ensureSchema(database);
    const jwt_secret = am.env.get(allocator, "JWT_SECRET") orelse try allocator.dupe(u8, "development-only-jwt-secret-change-me");
    defer allocator.free(jwt_secret);
    const login_secret = am.env.get(allocator, "LOGIN_SECRET") orelse try allocator.dupe(u8, "development-login-secret");
    defer allocator.free(login_secret);
    var app = am.App(application.State).init(allocator, .{ .db = database, .objects = files.store(), .jwt_secret = jwt_secret, .login_secret = login_secret, .schema_ready = true });
    defer app.deinit();
    try application.register(&app);
    try app.serve(.{ .port = 8080 });
}
