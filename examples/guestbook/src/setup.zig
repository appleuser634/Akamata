// Shared wiring used by both main.zig (native) and worker.zig (Workers).
// The DB backend is selected from DATABASE_URL; the schema is provisioned
// from the model definitions via am.model.migrate.

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const h = @import("handlers.zig");
const models = @import("models.zig");

pub const default_native_url = "file:guestbook.db";
pub const default_workers_url = "d1:DB";

/// Process-wide one-shot guard used by the deferred-migrate middleware on
/// Workers. Native builds run migrate from `buildState` so this stays at
/// "done" without ever firing.
var migrate_once: am.model.migrate.Once = .{};

fn ensureSchema(c: *am.Context(App), next: am.Next(App)) anyerror!void {
    if (am.backend == .workers) {
        migrate_once.run(c.arena, c.state().db, &models.all_models) catch |e| {
            std.log.warn("deferred migrate failed: {t}", .{e});
        };
    }
    return next.run(c);
}

pub fn registerRoutes(app: *am.App(App)) !void {
    _ = try app.useAll(am.mw.recover(App));
    _ = try app.useAll(am.mw.logger(App));
    // On Workers, first request triggers schema migration through JSPI.
    _ = try app.useAll(am.Middleware(App){ .name = "ensureSchema", .call = ensureSchema });

    _ = try app.get("/", h.index);
    _ = try app.get("/health", h.health);
    _ = try app.get("/entries", h.listEntries);
    _ = try app.post("/entries", h.createEntry);
    _ = try app.get("/entries/:id", h.showEntry);
    _ = try app.delete("/entries/:id", h.deleteEntry);
}

pub fn buildState(alloc: std.mem.Allocator) !App {
    if (am.backend == .native) am.env.loadDotEnv(alloc, ".env") catch {};

    const url = am.env.get(alloc, "DATABASE_URL") orelse blk: {
        const def = if (am.backend == .native) default_native_url else default_workers_url;
        break :blk try alloc.dupe(u8, def);
    };

    const database = try am.db.open(alloc, url);

    // Auto-migrate against the live DB. Only run during `buildState` on the
    // native side — Workers' `akamata_init` is called from the JS host's
    // `instantiate()` step where `WebAssembly.promising` isn't active yet,
    // so any D1 (JSPI) call would throw `SuspendError`. On Workers we either
    //   1. apply the schema out-of-band before deploy:
    //        ./guestbook --print-schema > /tmp/guestbook.sql
    //        akamata deploy --workers --migrate=/tmp/guestbook.sql
    //   2. or let the framework run migrate from the first `fetch()` (TODO,
    //      tracked separately) when the wasm stack is already inside a
    //      promising-wrapped call.
    // For Turso on native this works the same way as SQLite: HTTP DDL is
    // synchronous through our std.net path, no JSPI involvement.
    if (am.backend == .native) {
        var arena_state: std.heap.ArenaAllocator = .init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const plan = am.model.migrate.diff(arena, database, &models.all_models) catch |e| {
            std.log.warn("migrate.diff failed (skipping): {t}", .{e});
            return .{ .db = database };
        };
        am.model.migrate.apply(arena, database, plan) catch |e| {
            std.log.warn("migrate.apply failed: {t}", .{e});
        };
    }

    return .{ .db = database };
}
