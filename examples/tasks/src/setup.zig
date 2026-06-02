//! Wiring shared between native and Workers entry points.
//!
//! The goal of this file is to keep `main.zig` short and focused on
//! process lifecycle (signals, threads, dotenv) while every framework-
//! level decision (which middleware, which routes, how OpenAPI gets fed)
//! lives here.

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const EventChannel = @import("app.zig").EventChannel;
const h = @import("handlers.zig");
const models = @import("models.zig");

/// One-shot guard for the deferred Workers migration. Native builds run
/// migrate from `buildState` synchronously, so this stays unused there.
var migrate_once: am.model.migrate.Once = .{};

/// Per-request middleware that triggers schema migration on the *first*
/// Workers request, where the wasm stack is already inside a
/// JSPI-promising frame and D1 calls are legal.
fn ensureSchema(c: *am.Context(App), next: am.Next(App)) anyerror!void {
    if (am.backend == .workers) {
        migrate_once.run(c.arena, c.state().db, &models.all_models) catch |e| {
            std.log.warn("deferred migrate failed: {t}", .{e});
        };
    }
    return next.run(c);
}

/// Build and return a fully-configured `am.App(App)`. The caller owns it
/// and is responsible for calling `serve(...)` and `deinit()`.
///
/// Order matters here:
///   1. Build state (open DB, allocate channels/queues).
///   2. Create the framework App and stash a pointer back into state.
///   3. Register middleware (outer-first; later .use() calls run later).
///   4. Register routes.
///   5. (Native) start the job worker thread.
///
/// We split this from `main.zig` so the test suite can build the same
/// app graph and exercise it via `am.testing.Client`.
pub fn buildApp(alloc: std.mem.Allocator) !*am.App(App) {
    if (am.backend == .native) am.env.loadDotEnv(alloc, ".env") catch {};

    // ---- 1. open DB --------------------------------------------------
    const url = am.env.get(alloc, "DATABASE_URL") orelse blk: {
        const def = if (am.backend == .native) "file:tasks.db" else "d1:DB";
        break :blk try alloc.dupe(u8, def);
    };
    const database = try am.db.open(alloc, url);

    // Native: run migrations synchronously, before we accept traffic. On
    // Workers this happens lazily inside `ensureSchema` (see above).
    if (am.backend == .native) {
        var arena_state: std.heap.ArenaAllocator = .init(alloc);
        defer arena_state.deinit();
        const plan = try am.model.migrate.diff(arena_state.allocator(), database, &models.all_models);
        try am.model.migrate.apply(arena_state.allocator(), database, plan);
    }

    // ---- 2. assemble State + framework App --------------------------
    const app_ptr = try alloc.create(am.App(App));
    app_ptr.* = am.App(App).init(alloc, .{ .db = database });

    if (comptime am.backend == .native) {
        // Long-lived channels/queues live on the heap so the framework
        // can hand pointers to State without the underlying value moving.
        // `app.own(...)` ties their lifetime to the App so we don't have
        // to write a parallel destructor in main.zig.
        const events = try alloc.create(EventChannel);
        events.* = EventChannel.init(alloc);
        try app_ptr.own(events);
        app_ptr.state().events = events;

        const queue = try alloc.create(am.jobs.Queue);
        queue.* = try am.jobs.Queue.init(alloc, database, .{
            .poll_interval_ms = 200,
        });
        try queue.handler("notify", h.notifyJob);
        try app_ptr.own(queue);
        app_ptr.state().jobs = queue;
    }
    // (handlers reach back into the framework via `c.app()`; no manual
    // back-reference needed.)

    // ---- 3. middleware stack ----------------------------------------
    //
    // Order is "outer-first". `recover` wraps everything so a panic/return
    // becomes a 500. `logger` wraps the rest so even bad-request handlers
    // appear in the log. `secureHeaders` and `compress` are body-modifiers
    // and run last (closest to the handler).
    _ = try app_ptr.useAll(am.mw.recover(App));
    _ = try app_ptr.useAll(am.mw.logger(App));
    _ = try app_ptr.useAll(am.Middleware(App){ .name = "ensureSchema", .call = ensureSchema });
    _ = try app_ptr.useAll(am.mw.requestId(App));
    _ = try app_ptr.useAll(am.mw.cors(App, .{}));
    _ = try app_ptr.useAll(am.mw.secureHeaders(App, .{}));
    _ = try app_ptr.useAll(am.mw.compress(App, .{ .min_bytes = 512 }));
    _ = try app_ptr.useAll(am.mw.etag(App, .{}));

    // ---- 4. routes --------------------------------------------------
    //
    // Documented endpoints go through `app.endpoint(...)` so the OpenAPI
    // and client_gen helpers can see them. The undocumented routes
    // (events / docs / health) use the bare `app.get/post` form, which
    // skips the metadata.

    _ = try app_ptr.endpoint(.GET, "/tasks", h.listTasks, am.openapi.Spec(.{
        .response = h.TaskList,
        .query = h.ListQuery,
        .summary = "List all tasks",
        .tags = &.{"tasks"},
    }));
    _ = try app_ptr.endpoint(.POST, "/tasks", h.createTask, am.openapi.Spec(.{
        .request = h.CreateTaskInput,
        .response = @import("models.zig").Task,
        .summary = "Create a task",
        .tags = &.{"tasks"},
    }));
    _ = try app_ptr.endpoint(.GET, "/tasks/:id", h.showTask, am.openapi.Spec(.{
        .response = @import("models.zig").Task,
        .summary = "Fetch one task",
        .tags = &.{"tasks"},
    }));
    _ = try app_ptr.endpoint(.PATCH, "/tasks/:id", h.updateTask, am.openapi.Spec(.{
        .request = h.UpdateTaskInput,
        .response = @import("models.zig").Task,
        .summary = "Update a task",
        .tags = &.{"tasks"},
    }));
    _ = try app_ptr.endpoint(.DELETE, "/tasks/:id", h.deleteTask, am.openapi.Spec(.{
        .summary = "Delete a task",
        .tags = &.{"tasks"},
    }));

    // Undocumented (or self-describing) routes.
    _ = try app_ptr.get("/events", h.streamEvents);
    _ = try app_ptr.get("/openapi.json", h.openapiSpec);
    _ = try app_ptr.get("/client.ts", h.typescriptClient);
    _ = try app_ptr.get("/health", healthCheck);

    return app_ptr;
}

fn healthCheck(c: *am.Context(App)) !void {
    // A minimal liveness probe. Real apps might also exercise the DB.
    try c.json(.{ .status = "ok", .backend = @tagName(am.backend) }, 200);
}
