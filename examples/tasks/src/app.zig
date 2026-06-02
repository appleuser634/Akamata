//! Application state.
//!
//! Whatever fields you put here are reachable from every handler via
//! `c.state()` (and `c.db()` / `c.cfg()` shortcuts if you name the fields
//! `db` / `cfg`).
//!
//! Keep this small. The State is shared across all request threads, so
//! mutable fields need to be thread-safe (`std.atomic.Value`, a Mutex, or
//! lock-free data structures). Per-request data belongs in `c.user_data`
//! or in the request's arena (`c.arena`).

const am = @import("akamata");
const std = @import("std");

pub const App = struct {
    /// Database handle. The Db is itself a vtable — backend (SQLite /
    /// Turso / D1) is decided by `am.db.open(url)` and the handlers don't
    /// care which one is live.
    db: am.db.Db,

    /// SSE broadcaster. Every time a task is created or updated, we push
    /// a JSON event into this channel; the `/events` endpoint subscribes
    /// to it. Native-only — Workers does pub/sub via Durable Objects, and
    /// we don't ship the bridge in this example.
    events: if (am.backend == .native) *EventChannel else void = if (am.backend == .native) undefined else {},

    /// Background job queue. Same story — native-only here. Workers users
    /// should reach for Cron Triggers + Durable Object Alarms instead.
    jobs: if (am.backend == .native) *am.jobs.Queue else void = if (am.backend == .native) undefined else {},
};

/// A tiny pub/sub for SSE consumers. The handler that creates/updates a
/// task calls `publish(...)`; every connected `/events` subscriber polls
/// for new items. The slot list is a ring; the seq counter is monotonic.
///
/// We picked polling over Mutex+Condition because:
///   * `std.Thread.Mutex` doesn't exist in Zig 0.16; we'd need libc pthread.
///   * SSE delivery is naturally event-driven from the client's side, and
///     server-side latency of 50 ms (the poll interval) is fine for a UI.
///
/// One channel covers the whole app to keep the example readable; real
/// apps would key by user/room/topic.
pub const EventChannel = struct {
    const Slot = struct {
        seq: u64,
        bytes: []u8,
    };
    const ring_capacity = 64;

    gpa: std.mem.Allocator,
    mutex: am.sync.Mutex,
    /// Monotonic event id. Subscribers track the last id they've seen and
    /// only read newer slots.
    next_seq: u64 = 1,
    slots: [ring_capacity]Slot = [_]Slot{.{ .seq = 0, .bytes = &.{} }} ** ring_capacity,

    pub fn init(gpa: std.mem.Allocator) EventChannel {
        return .{
            .gpa = gpa,
            .mutex = am.sync.Mutex.init(),
        };
    }

    pub fn deinit(self: *EventChannel) void {
        for (self.slots) |s| if (s.bytes.len > 0) self.gpa.free(s.bytes);
        self.mutex.deinit();
    }

    /// Push an event. The newest `ring_capacity` events are retained;
    /// older ones are evicted (subscribers should be reading often
    /// enough that this doesn't matter in practice).
    pub fn publish(self: *EventChannel, bytes: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const owned = try self.gpa.dupe(u8, bytes);
        const idx = self.next_seq % ring_capacity;
        if (self.slots[idx].bytes.len > 0) self.gpa.free(self.slots[idx].bytes);
        self.slots[idx] = .{ .seq = self.next_seq, .bytes = owned };
        self.next_seq += 1;
    }

    /// Return the newest event whose seq > `since_seq`, or null if no
    /// such event exists. The returned slice is owned by the channel —
    /// copy it before unlocking if you need it to outlive the call.
    pub fn pollAfter(self: *EventChannel, since_seq: u64) ?Slot {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.next_seq <= since_seq + 1) return null;
        const idx = (self.next_seq - 1) % ring_capacity;
        return self.slots[idx];
    }
};
