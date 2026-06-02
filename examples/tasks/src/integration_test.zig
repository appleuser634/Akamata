//! End-to-end tests for the tasks example, exercised through
//! `am.testing.Client` — no port binding, no thread shenanigans, just
//! direct `app.dispatch` invocations against a real (in-memory) DB.

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const EventChannel = @import("app.zig").EventChannel;
const h = @import("handlers.zig");
const models = @import("models.zig");

/// Spin up a minimal app graph that mirrors what `setup.buildApp` would
/// produce — but without dotenv loading, signal handlers, or a worker
/// thread. The DB is in-memory so each test starts fresh.
fn newApp(alloc: std.mem.Allocator) !*am.App(App) {
    const db = try am.db.openSqlite(alloc, ":memory:");

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const plan = try am.model.migrate.diff(arena_state.allocator(), db, &models.all_models);
    try am.model.migrate.apply(arena_state.allocator(), db, plan);

    const app_ptr = try alloc.create(am.App(App));
    app_ptr.* = am.App(App).init(alloc, .{ .db = db });

    const events = try alloc.create(EventChannel);
    events.* = EventChannel.init(alloc);
    try app_ptr.own(events);
    app_ptr.state().events = events;

    const queue = try alloc.create(am.jobs.Queue);
    queue.* = try am.jobs.Queue.init(alloc, db, .{ .poll_interval_ms = 100 });
    try queue.handler("notify", h.notifyJob);
    try app_ptr.own(queue);
    app_ptr.state().jobs = queue;

    // Don't install logger/recover in tests — we want raw error propagation
    // so assertion failures don't get swallowed.

    _ = try app_ptr.endpoint(.GET, "/tasks", h.listTasks, am.openapi.Spec(.{
        .response = h.TaskList,
        .query = h.ListQuery,
    }));
    _ = try app_ptr.endpoint(.POST, "/tasks", h.createTask, am.openapi.Spec(.{
        .request = h.CreateTaskInput,
        .response = models.Task,
    }));
    _ = try app_ptr.endpoint(.GET, "/tasks/:id", h.showTask, am.openapi.Spec(.{
        .response = models.Task,
    }));
    _ = try app_ptr.endpoint(.PATCH, "/tasks/:id", h.updateTask, am.openapi.Spec(.{
        .request = h.UpdateTaskInput,
        .response = models.Task,
    }));
    _ = try app_ptr.endpoint(.DELETE, "/tasks/:id", h.deleteTask, am.openapi.Spec(.{}));

    return app_ptr;
}

fn destroyApp(alloc: std.mem.Allocator, app_ptr: *am.App(App)) void {
    // `app.deinit()` walks resources registered with `app.own(...)` —
    // the test only has to close the DB and destroy the App itself.
    app_ptr.state().db.close();
    app_ptr.deinit();
    alloc.destroy(app_ptr);
}

test "POST /tasks creates a task" {
    const alloc = std.testing.allocator;
    const app_ptr = try newApp(alloc);
    defer destroyApp(alloc, app_ptr);

    var client = am.testing.Client(am.App(App)).init(alloc, app_ptr);
    defer client.deinit();

    var resp = try client.post("/tasks").json(.{ .title = "buy milk" }).send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 201), resp.status);

    const Out = struct { id: i64, title: []const u8, done: bool };
    const created = try resp.json(Out);
    try std.testing.expectEqualStrings("buy milk", created.title);
    try std.testing.expect(created.id > 0);
    try std.testing.expect(!created.done);
}

test "POST /tasks rejects missing title with 422" {
    const alloc = std.testing.allocator;
    const app_ptr = try newApp(alloc);
    defer destroyApp(alloc, app_ptr);

    var client = am.testing.Client(am.App(App)).init(alloc, app_ptr);
    defer client.deinit();

    // Empty title fails both `required` and `min_len(1)`.
    var resp = try client.post("/tasks").json(.{ .title = "" }).send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 422), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"field\":\"title\"") != null);
}

test "GET /tasks/:id returns 404 for unknown id" {
    const alloc = std.testing.allocator;
    const app_ptr = try newApp(alloc);
    defer destroyApp(alloc, app_ptr);

    var client = am.testing.Client(am.App(App)).init(alloc, app_ptr);
    defer client.deinit();

    var resp = try client.get("/tasks/9999").send();
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "PATCH /tasks/:id flips done" {
    const alloc = std.testing.allocator;
    const app_ptr = try newApp(alloc);
    defer destroyApp(alloc, app_ptr);

    var client = am.testing.Client(am.App(App)).init(alloc, app_ptr);
    defer client.deinit();

    // Create.
    var created_resp = try client.post("/tasks").json(.{ .title = "ship release" }).send();
    const id = blk: {
        const Out = struct { id: i64 };
        const created = try created_resp.json(Out);
        break :blk created.id;
    };
    created_resp.deinit();

    // Toggle done. `patchf` allocates the path via the gpa and tracks it
    // for cleanup, so no `defer alloc.free(...)` is needed.
    var patch_resp = try client.patchf("/tasks/{d}", .{id}).json(.{ .done = true }).send();
    defer patch_resp.deinit();

    try std.testing.expectEqual(@as(u16, 200), patch_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, patch_resp.body, "\"done\":true") != null);
}

test "DELETE /tasks/:id removes the row" {
    const alloc = std.testing.allocator;
    const app_ptr = try newApp(alloc);
    defer destroyApp(alloc, app_ptr);

    var client = am.testing.Client(am.App(App)).init(alloc, app_ptr);
    defer client.deinit();

    var c1 = try client.post("/tasks").json(.{ .title = "x" }).send();
    const id = (try c1.json(struct { id: i64 })).id;
    c1.deinit();

    var del = try client.deletef("/tasks/{d}", .{id}).send();
    defer del.deinit();
    try std.testing.expectEqual(@as(u16, 200), del.status);

    var miss = try client.getf("/tasks/{d}", .{id}).send();
    defer miss.deinit();
    try std.testing.expectEqual(@as(u16, 404), miss.status);
}
