//! Persistent background job queue + cron, backed by the app's own DB.
//!
//! Three primitives:
//!
//!   * `Queue` — a SQLite-backed work table (`akamata_jobs`) with at-least-
//!     once delivery, configurable retries, and a `scheduled_for` column for
//!     deferred execution.
//!   * `Worker.run` — a polling loop that dequeues due jobs and dispatches
//!     them to handlers registered by `Queue.handler`.
//!   * `Cron` — registers periodic jobs by evaluating a tiny `every` syntax
//!     (seconds-resolution) against the wall clock on each tick.
//!
//! On Workers, this whole module is unavailable — Cloudflare provides
//! native Cron Triggers and Durable Object Alarms that should be used
//! instead. A future task can add an extern fn bridge so the same
//! handler-registration API works on both backends.
//!
//! Design choices:
//!
//!   * Polling instead of `LISTEN/NOTIFY`: SQLite doesn't have it, and the
//!     poll interval is configurable; for cron-like workloads ~1 s is fine.
//!   * Status states: `pending | running | succeeded | failed`. We *don't*
//!     delete jobs on success — they stay so app authors can audit/replay.
//!     A `cleanup` helper purges old finished rows.
//!   * Payload is opaque bytes; convention is JSON but the worker doesn't
//!     parse it. Handlers receive raw `[]const u8`.

const std = @import("std");
const db_mod = @import("db/db.zig");

/// Unix epoch seconds. Zig 0.16 std.time dropped `timestamp()`, so we go
/// straight to libc.
extern "c" fn time(t: ?*i64) i64;
extern "c" fn usleep(usecs: c_uint) c_int;
fn nowUnix() i64 {
    return time(null);
}
fn sleepMs(ms: u32) void {
    _ = usleep(@as(c_uint, ms) * 1000);
}

pub const Error = error{
    QueueClosed,
    HandlerMissing,
};

/// SQL DDL for the jobs table. Idempotent — safe to call on every boot.
pub const schema_sql =
    \\CREATE TABLE IF NOT EXISTS akamata_jobs (
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  payload TEXT NOT NULL,
    \\  scheduled_for INTEGER NOT NULL,
    \\  attempts INTEGER NOT NULL DEFAULT 0,
    \\  max_attempts INTEGER NOT NULL DEFAULT 3,
    \\  status TEXT NOT NULL DEFAULT 'pending',
    \\  last_error TEXT,
    \\  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    \\  updated_at INTEGER NOT NULL DEFAULT (unixepoch())
    \\) STRICT;
    \\CREATE INDEX IF NOT EXISTS akamata_jobs_pending_idx
    \\  ON akamata_jobs(status, scheduled_for)
    \\  WHERE status = 'pending';
;

pub const HandlerFn = *const fn (gpa: std.mem.Allocator, payload: []const u8) anyerror!void;

const Handler = struct {
    name: []const u8,
    func: HandlerFn,
};

const CronEntry = struct {
    name: []const u8,
    /// Period in seconds. Wall-clock based; on every tick we check if
    /// `now >= last_fired + period_seconds`.
    period_seconds: i64,
    payload: []const u8 = "",
    last_fired_unix: i64 = 0,
};

pub const Options = struct {
    /// How often the worker checks the table for new pending jobs.
    poll_interval_ms: u32 = 1000,
    /// Initial delay before the first retry of a failing job. Doubled per
    /// attempt (capped at max_backoff_seconds).
    initial_backoff_seconds: i64 = 5,
    max_backoff_seconds: i64 = 3600,
    /// Soft cap on rows fetched per poll. Keeps a single worker from
    /// hogging the connection during a backlog.
    batch_size: u32 = 32,
};

pub const Queue = struct {
    gpa: std.mem.Allocator,
    db: db_mod.Db,
    handlers: std.ArrayList(Handler) = .empty,
    crons: std.ArrayList(CronEntry) = .empty,
    opts: Options,
    /// Set by `Worker.stop()` so `Worker.run` exits cleanly at the next
    /// poll boundary.
    shutdown: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, db: db_mod.Db, opts: Options) !Queue {
        try db.execAll(schema_sql);
        return .{ .gpa = gpa, .db = db, .opts = opts };
    }

    pub fn deinit(self: *Queue) void {
        self.handlers.deinit(self.gpa);
        self.crons.deinit(self.gpa);
    }

    /// Register a handler for `name`. Jobs enqueued with that same `name`
    /// will be dispatched here. Re-registering replaces the previous handler.
    pub fn handler(self: *Queue, name: []const u8, func: HandlerFn) !void {
        for (self.handlers.items) |*h| {
            if (std.mem.eql(u8, h.name, name)) {
                h.func = func;
                return;
            }
        }
        try self.handlers.append(self.gpa, .{ .name = name, .func = func });
    }

    /// Schedule a job. `payload` is copied into the DB row.
    pub fn enqueue(self: *Queue, name: []const u8, payload: []const u8, opts: EnqueueOptions) !i64 {
        const now = nowUnix();
        const scheduled = now + opts.delay_seconds;
        var stmt = try self.db.prepare(
            "INSERT INTO akamata_jobs(name, payload, scheduled_for, max_attempts) VALUES(?, ?, ?, ?) RETURNING id",
        );
        defer stmt.deinit();
        try stmt.bindAll(.{ name, payload, scheduled, @as(i64, @intCast(opts.max_attempts)) });
        if ((try stmt.step()) != .row) return error.QueueClosed;
        const Row = struct { id: i64 };
        const row = try stmt.readRow(Row);
        return row.id;
    }

    /// Register a periodic job that fires every `period_seconds`. The job
    /// is treated as if it were enqueued (with `name`/`payload`) at each
    /// firing — the same handler executes it.
    pub fn cron(self: *Queue, name: []const u8, period_seconds: i64, payload: []const u8) !void {
        try self.crons.append(self.gpa, .{
            .name = name,
            .period_seconds = period_seconds,
            .payload = payload,
        });
    }

    /// Delete `succeeded` / terminally-`failed` rows older than `older_than_seconds`.
    pub fn cleanup(self: *Queue, older_than_seconds: i64) !void {
        const cutoff = nowUnix() - older_than_seconds;
        var stmt = try self.db.prepare(
            \\DELETE FROM akamata_jobs
            \\WHERE (status = 'succeeded' OR status = 'failed') AND updated_at < ?
        );
        defer stmt.deinit();
        try stmt.bindAll(.{cutoff});
        _ = try stmt.step();
    }
};

pub const EnqueueOptions = struct {
    /// Defer the job by this many seconds. Default 0 = run as soon as
    /// possible.
    delay_seconds: i64 = 0,
    /// After this many failed attempts the job is marked as `failed` and
    /// won't be retried.
    max_attempts: u32 = 3,
};

pub const Worker = struct {
    queue: *Queue,

    pub fn init(queue: *Queue) Worker {
        return .{ .queue = queue };
    }

    /// Run the polling loop on the current thread until `stop()` is called.
    /// Typical use: spawn this on its own thread.
    pub fn run(self: *Worker) !void {
        const q = self.queue;
        while (!q.shutdown.load(.seq_cst)) {
            try self.tickCrons();
            try self.drainBatch();
            sleepMs(q.opts.poll_interval_ms);
        }
    }

    pub fn stop(self: *Worker) void {
        self.queue.shutdown.store(true, .seq_cst);
    }

    fn tickCrons(self: *Worker) !void {
        const now = nowUnix();
        const q = self.queue;
        for (q.crons.items) |*c| {
            if (now >= c.last_fired_unix + c.period_seconds) {
                _ = try q.enqueue(c.name, c.payload, .{});
                c.last_fired_unix = now;
            }
        }
    }

    fn drainBatch(self: *Worker) !void {
        const q = self.queue;
        const now = nowUnix();

        // Fetch a batch of due rows. We can't keep a prepared statement
        // open across the dispatch (handler may itself touch the DB on the
        // same connection), so we collect into memory first.
        var batch: std.ArrayList(JobRow) = .empty;
        defer {
            for (batch.items) |r| {
                q.gpa.free(r.name);
                q.gpa.free(r.payload);
            }
            batch.deinit(q.gpa);
        }

        var sel = try q.db.prepare(
            \\SELECT id, name, payload, attempts, max_attempts
            \\FROM akamata_jobs
            \\WHERE status = 'pending' AND scheduled_for <= ?
            \\ORDER BY scheduled_for
            \\LIMIT ?
        );
        defer sel.deinit();
        try sel.bindAll(.{ now, @as(i64, @intCast(q.opts.batch_size)) });
        const Row = struct {
            id: i64,
            name: []const u8,
            payload: []const u8,
            attempts: i64,
            max_attempts: i64,
        };
        while ((try sel.step()) == .row) {
            const r = try sel.readRow(Row);
            try batch.append(q.gpa, .{
                .id = r.id,
                .name = try q.gpa.dupe(u8, r.name),
                .payload = try q.gpa.dupe(u8, r.payload),
                .attempts = r.attempts,
                .max_attempts = r.max_attempts,
            });
        }

        for (batch.items) |row| {
            try self.dispatchOne(row);
        }
    }

    fn dispatchOne(self: *Worker, row: JobRow) !void {
        const q = self.queue;

        // Find the handler.
        const handler_fn: ?HandlerFn = blk: {
            for (q.handlers.items) |h| {
                if (std.mem.eql(u8, h.name, row.name)) break :blk h.func;
            }
            break :blk null;
        };
        if (handler_fn == null) {
            try self.markFailed(row, "no handler registered");
            return;
        }

        // Mark running first so a parallel worker can't grab it. (Not a
        // true lock — SQLite + multiple workers would need SELECT FOR
        // UPDATE; we ship a single-worker design for now.)
        try self.setStatus(row.id, "running", row.attempts);

        handler_fn.?(q.gpa, row.payload) catch |err| {
            const next_attempts = row.attempts + 1;
            if (next_attempts >= row.max_attempts) {
                try self.markFailed(row, @errorName(err));
            } else {
                const backoff = computeBackoff(q.opts, next_attempts);
                try self.reschedule(row.id, next_attempts, backoff, @errorName(err));
            }
            return;
        };
        try self.markSucceeded(row.id);
    }

    fn setStatus(self: *Worker, id: i64, status: []const u8, attempts: i64) !void {
        const q = self.queue;
        var stmt = try q.db.prepare(
            \\UPDATE akamata_jobs
            \\SET status = ?, attempts = ?, updated_at = unixepoch()
            \\WHERE id = ?
        );
        defer stmt.deinit();
        try stmt.bindAll(.{ status, attempts, id });
        _ = try stmt.step();
    }

    fn markSucceeded(self: *Worker, id: i64) !void {
        const q = self.queue;
        var stmt = try q.db.prepare(
            "UPDATE akamata_jobs SET status = 'succeeded', updated_at = unixepoch() WHERE id = ?",
        );
        defer stmt.deinit();
        try stmt.bindAll(.{id});
        _ = try stmt.step();
    }

    fn markFailed(self: *Worker, row: JobRow, reason: []const u8) !void {
        const q = self.queue;
        var stmt = try q.db.prepare(
            \\UPDATE akamata_jobs
            \\SET status = 'failed', last_error = ?, updated_at = unixepoch()
            \\WHERE id = ?
        );
        defer stmt.deinit();
        try stmt.bindAll(.{ reason, row.id });
        _ = try stmt.step();
    }

    fn reschedule(self: *Worker, id: i64, attempts: i64, backoff: i64, reason: []const u8) !void {
        const q = self.queue;
        const next = nowUnix() + backoff;
        var stmt = try q.db.prepare(
            \\UPDATE akamata_jobs
            \\SET status = 'pending', attempts = ?, scheduled_for = ?,
            \\    last_error = ?, updated_at = unixepoch()
            \\WHERE id = ?
        );
        defer stmt.deinit();
        try stmt.bindAll(.{ attempts, next, reason, id });
        _ = try stmt.step();
    }
};

const JobRow = struct {
    id: i64,
    name: []const u8,
    payload: []const u8,
    attempts: i64,
    max_attempts: i64,
};

fn computeBackoff(opts: Options, attempts: i64) i64 {
    // Exponential: initial * 2^(attempts-1), capped at max.
    if (attempts <= 1) return opts.initial_backoff_seconds;
    var seconds = opts.initial_backoff_seconds;
    var i: i64 = 1;
    while (i < attempts) : (i += 1) {
        seconds *|= 2;
        if (seconds >= opts.max_backoff_seconds) return opts.max_backoff_seconds;
    }
    return seconds;
}

test "computeBackoff doubles per attempt and caps" {
    const opts: Options = .{
        .initial_backoff_seconds = 5,
        .max_backoff_seconds = 60,
    };
    try std.testing.expectEqual(@as(i64, 5), computeBackoff(opts, 1));
    try std.testing.expectEqual(@as(i64, 10), computeBackoff(opts, 2));
    try std.testing.expectEqual(@as(i64, 20), computeBackoff(opts, 3));
    try std.testing.expectEqual(@as(i64, 40), computeBackoff(opts, 4));
    try std.testing.expectEqual(@as(i64, 60), computeBackoff(opts, 5)); // capped
}
