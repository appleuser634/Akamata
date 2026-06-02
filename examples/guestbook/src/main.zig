// Native entry. Reads DATABASE_URL from env (or .env) and serves on PORT.
//
// Subcommands (positional argv[1]):
//   --print-schema     Emit DDL SQL from `models.zig` and exit.
//   migrate-up [--dir=DIR]
//                      Apply pending versioned migrations against the live
//                      DB. Records each in `schema_migrations`. DIR defaults
//                      to ./migrations. Companion to `akamata migrate up`.
//
// Otherwise: serve HTTP on $PORT (default 8080).

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const setup = @import("setup.zig");
const models = @import("models.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());
    // args[0] = exe; args[1..] = user-provided.
    if (args.len >= 2) {
        const arg = std.mem.sliceTo(args[1], 0);
        if (std.mem.eql(u8, arg, "--print-schema")) {
            return printSchema(alloc);
        }
        if (std.mem.eql(u8, arg, "migrate-up")) {
            return migrateUp(alloc, args[2..]);
        }
    }

    var app = am.App(App).init(alloc, try setup.buildState(alloc));
    defer app.deinit();
    try setup.registerRoutes(&app);

    const port_env = am.env.get(alloc, "PORT");
    defer if (port_env) |p| alloc.free(p);
    const port: u16 = if (port_env) |p|
        std.fmt.parseInt(u16, p, 10) catch 8080
    else
        8080;

    std.log.info("guestbook listening on :{d}", .{port});
    try app.serve(.{ .port = port });
}

fn migrateUp(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var dir: []const u8 = "migrations";
    for (args) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, a, "--dir=")) dir = a[6..];
    }
    am.env.loadDotEnv(alloc, ".env") catch {};
    const url = am.env.get(alloc, "DATABASE_URL") orelse try alloc.dupe(u8, "file:guestbook.db");
    defer alloc.free(url);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const database = try am.db.open(alloc, url);
    defer database.close();

    const all = try am.model.migrate.loadMigrationsFromDir(arena, dir);
    const m: am.model.migrate.Migrator = .{ .arena = arena, .db = database };
    const pending = try m.pending(all);
    if (pending.len == 0) {
        std.log.info("migrate-up: nothing pending ({d} total, all applied)", .{all.len});
        return;
    }
    for (pending) |mig| std.log.info("applying {s}", .{mig.name});
    try m.applyAll(pending);
    std.log.info("applied {d} migration(s)", .{pending.len});
}

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

fn printSchema(alloc: std.mem.Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Raw write(2) on fd=1 (stdout). Simpler than wiring a full `std.Io`
    // dispatcher for a one-shot print.
    for (models.all_models) |td| {
        const sql = try am.model.ddl.fullSchema(arena, td, .{});
        _ = write(1, sql.ptr, sql.len);
        _ = write(1, "\n".ptr, 1);
    }
}
