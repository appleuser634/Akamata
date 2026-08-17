const std = @import("std");
const db_mod = @import("db.zig");
const sync = @import("../sync.zig");

/// Bounded pool for independently opened database handles. The pool owns the
/// handles passed to `init` and closes them at `deinit`.
pub const Pool = struct {
    gpa: std.mem.Allocator,
    handles: []db_mod.Db,
    available: []bool,
    mu: sync.Mutex,
    changed: sync.Condition,
    closed: bool = false,

    pub fn init(gpa: std.mem.Allocator, handles: []const db_mod.Db) !Pool {
        if (handles.len == 0) return error.EmptyPool;
        const owned = try gpa.dupe(db_mod.Db, handles);
        errdefer gpa.free(owned);
        const available = try gpa.alloc(bool, handles.len);
        @memset(available, true);
        return .{
            .gpa = gpa,
            .handles = owned,
            .available = available,
            .mu = sync.Mutex.init(),
            .changed = sync.Condition.init(),
        };
    }

    pub fn acquire(self: *Pool) !Lease {
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            if (self.closed) return error.PoolClosed;
            for (self.available, 0..) |free, i| {
                if (free) {
                    self.available[i] = false;
                    return .{ .pool = self, .index = i, .db = self.handles[i] };
                }
            }
            self.changed.wait(&self.mu);
        }
    }

    pub fn deinit(self: *Pool) void {
        self.mu.lock();
        self.closed = true;
        for (self.available) |free| std.debug.assert(free);
        self.mu.unlock();
        self.changed.broadcast();
        for (self.handles) |db| db.close();
        self.gpa.free(self.handles);
        self.gpa.free(self.available);
        self.changed.deinit();
        self.mu.deinit();
    }

    fn release(self: *Pool, index: usize) void {
        self.mu.lock();
        std.debug.assert(!self.available[index]);
        self.available[index] = true;
        self.mu.unlock();
        self.changed.signal();
    }
};

pub const Lease = struct {
    pool: *Pool,
    index: usize,
    db: db_mod.Db,
    released: bool = false,

    pub fn deinit(self: *Lease) void {
        if (self.released) return;
        self.released = true;
        self.pool.release(self.index);
    }
};
