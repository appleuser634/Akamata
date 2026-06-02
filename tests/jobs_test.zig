const std = @import("std");
const am = @import("akamata");

extern "c" fn usleep(usecs: c_uint) c_int;
fn sleepMs(ms: u32) void {
    _ = usleep(@as(c_uint, ms) * 1000);
}

// A counter that handlers tick. Lives in static memory so handler fn ptrs
// (which can't capture local state) can observe it.
const Counter = struct {
    var value: std.atomic.Value(u32) = .init(0);
    var last_payload_buf: [256]u8 = undefined;
    var last_payload_len: std.atomic.Value(usize) = .init(0);
};

fn incHandler(_: std.mem.Allocator, payload: []const u8) !void {
    _ = Counter.value.fetchAdd(1, .seq_cst);
    const n = @min(payload.len, Counter.last_payload_buf.len);
    @memcpy(Counter.last_payload_buf[0..n], payload[0..n]);
    Counter.last_payload_len.store(n, .seq_cst);
}

test "jobs: enqueue + worker drains pending row" {
    Counter.value.store(0, .seq_cst);
    Counter.last_payload_len.store(0, .seq_cst);

    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();

    var queue = try am.jobs.Queue.init(alloc, db, .{ .poll_interval_ms = 10 });
    defer queue.deinit();

    try queue.handler("inc", incHandler);
    const id = try queue.enqueue("inc", "hello", .{});
    try std.testing.expect(id > 0);

    // Drive the worker for ~100 ms then stop.
    var worker = am.jobs.Worker.init(&queue);
    const t = try std.Thread.spawn(.{}, am.jobs.Worker.run, .{&worker});
    defer {
        worker.stop();
        t.join();
    }
    sleepMs(100);

    try std.testing.expectEqual(@as(u32, 1), Counter.value.load(.seq_cst));
    const n = Counter.last_payload_len.load(.seq_cst);
    try std.testing.expectEqualStrings("hello", Counter.last_payload_buf[0..n]);
}

test "jobs: unknown handler marks job as failed" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();

    var queue = try am.jobs.Queue.init(alloc, db, .{ .poll_interval_ms = 10 });
    defer queue.deinit();

    _ = try queue.enqueue("nonexistent", "", .{});

    var worker = am.jobs.Worker.init(&queue);
    const t = try std.Thread.spawn(.{}, am.jobs.Worker.run, .{&worker});
    defer {
        worker.stop();
        t.join();
    }
    sleepMs(80);

    var stmt = try db.prepare("SELECT status FROM akamata_jobs LIMIT 1");
    defer stmt.deinit();
    _ = try stmt.step();
    const Row = struct { status: []const u8 };
    const row = try stmt.readRow(Row);
    try std.testing.expectEqualStrings("failed", row.status);
}

test "jobs: schema is idempotent" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    var q1 = try am.jobs.Queue.init(alloc, db, .{});
    defer q1.deinit();
    var q2 = try am.jobs.Queue.init(alloc, db, .{});
    defer q2.deinit();
    // No panic = pass.
}
