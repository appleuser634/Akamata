//! Native entry point for the tasks example.
//!
//! Reads optional env vars (DATABASE_URL / PORT), builds the app via
//! `setup.buildApp`, starts the background job worker on a side thread,
//! then hands control to `app.serve(...)`. The serve loop blocks until
//! SIGINT/SIGTERM, at which point we stop the worker and exit cleanly.

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const setup = @import("setup.zig");

pub fn main(_: std.process.Init) !void {
    // DebugAllocator catches leaks during development. For production,
    // swap it for `std.heap.smp_allocator` or your favorite arena.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const app_ptr = try setup.buildApp(alloc);
    defer {
        // `app.deinit()` walks owned resources (events channel, jobs
        // queue) and tears them down in reverse registration order;
        // the example doesn't have to maintain a parallel destructor.
        app_ptr.deinit();
        alloc.destroy(app_ptr);
    }

    // Spin up a worker thread that polls the jobs table.
    const queue = app_ptr.state().jobs;
    var worker = am.jobs.Worker.init(queue);
    const worker_thread = try std.Thread.spawn(.{}, am.jobs.Worker.run, .{&worker});
    defer {
        worker.stop();
        worker_thread.join();
    }

    // Port is configurable via $PORT (default 8080).
    const port_str = am.env.get(alloc, "PORT");
    defer if (port_str) |s| alloc.free(s);
    const port: u16 = if (port_str) |s| std.fmt.parseInt(u16, s, 10) catch 8080 else 8080;

    std.log.info("akamata-tasks listening on http://0.0.0.0:{d}/", .{port});
    std.log.info("  routes:", .{});
    std.log.info("    GET    /tasks", .{});
    std.log.info("    POST   /tasks", .{});
    std.log.info("    GET    /tasks/:id", .{});
    std.log.info("    PATCH  /tasks/:id", .{});
    std.log.info("    DELETE /tasks/:id", .{});
    std.log.info("    GET    /events     (SSE)", .{});
    std.log.info("    GET    /openapi.json", .{});
    std.log.info("    GET    /client.ts", .{});
    std.log.info("    GET    /health", .{});

    try app_ptr.serve(.{ .port = port, .accept_thread_count = 4 });
}

