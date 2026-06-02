// Generic WebSocket Hub: in-memory map of `room key → []*Conn`. Stub on
// Workers (the JS Durable Object is the canonical broadcaster there).
//
// Typical use:
//
//     var hub = am.ws.Hub(u64).init(alloc);  // key by room_id
//     defer hub.deinit();
//
//     // in a handler …
//     var conn = try am.ws.upgrade(Ctx, c, .{});
//     defer conn.deinit();
//     try app.state().hub.attach(room_id, &conn);
//     defer app.state().hub.detach(room_id, &conn);
//     while (true) { … hub.broadcast(room_id, msg) … }
//
// `Key` may be any hashable type (u64 for room IDs, []const u8 for user ids,
// etc.). For []const u8 keys, the hub copies them on `attach` and frees on
// `detach` / `deinit` so the caller doesn't have to manage lifetimes.

const std = @import("std");
const build_options = @import("build_options");
const sync = @import("../sync.zig");
const conn_mod = @import("conn.zig");

const is_native = build_options.backend == .native;

pub fn Hub(comptime Key: type) type {
    if (!is_native) return WorkersStub(Key);
    return NativeHub(Key);
}

fn keyEqual(a: anytype, b: @TypeOf(a)) bool {
    if (@TypeOf(a) == []const u8) return std.mem.eql(u8, a, b);
    return a == b;
}

fn NativeHub(comptime Key: type) type {
    const string_key = Key == []const u8;
    const MapT = if (string_key)
        std.StringHashMap(std.ArrayList(*conn_mod.Conn))
    else
        std.AutoHashMap(Key, std.ArrayList(*conn_mod.Conn));

    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        mu: sync.Mutex,
        rooms: MapT,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
                .mu = sync.Mutex.init(),
                .rooms = MapT.init(gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.rooms.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.gpa);
                if (comptime string_key) self.gpa.free(entry.key_ptr.*);
            }
            self.rooms.deinit();
            self.mu.deinit();
        }

        pub fn attach(self: *Self, key: Key, conn: *conn_mod.Conn) !void {
            self.mu.lock();
            defer self.mu.unlock();
            const stored_key: Key = if (comptime string_key)
                try self.gpa.dupe(u8, key)
            else
                key;
            const gop = try self.rooms.getOrPut(stored_key);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            } else if (comptime string_key) {
                // Reuse the existing copy of the key.
                self.gpa.free(stored_key);
            }
            try gop.value_ptr.append(self.gpa, conn);
        }

        pub fn detach(self: *Self, key: Key, conn: *conn_mod.Conn) void {
            self.mu.lock();
            defer self.mu.unlock();
            const entry = self.rooms.getPtr(key) orelse return;
            var i: usize = 0;
            while (i < entry.items.len) : (i += 1) {
                if (entry.items[i] == conn) {
                    _ = entry.swapRemove(i);
                    break;
                }
            }
            if (entry.items.len == 0) {
                if (comptime string_key) {
                    if (self.rooms.fetchRemove(key)) |kv| {
                        var v = kv.value;
                        v.deinit(self.gpa);
                        self.gpa.free(kv.key);
                    }
                } else {
                    if (self.rooms.fetchRemove(key)) |kv| {
                        var v = kv.value;
                        v.deinit(self.gpa);
                    }
                }
            }
        }

        /// Broadcast a text frame to every connection registered to `key`.
        /// Each `sendText` failure detaches the offending connection so
        /// stale peers don't accumulate.
        pub fn broadcast(self: *Self, key: Key, payload: []const u8) !void {
            // Snapshot the conn list under the lock so the actual writes
            // happen lock-free (avoids holding the hub mutex during a send).
            var snapshot_buf: [256]*conn_mod.Conn = undefined;
            var n: usize = 0;
            self.mu.lock();
            if (self.rooms.getPtr(key)) |entry| {
                n = @min(entry.items.len, snapshot_buf.len);
                @memcpy(snapshot_buf[0..n], entry.items[0..n]);
            }
            self.mu.unlock();

            var failed_buf: [256]*conn_mod.Conn = undefined;
            var failed_n: usize = 0;
            for (snapshot_buf[0..n]) |conn| {
                conn.sendText(payload) catch {
                    if (failed_n < failed_buf.len) {
                        failed_buf[failed_n] = conn;
                        failed_n += 1;
                    }
                };
            }
            for (failed_buf[0..failed_n]) |conn| self.detach(key, conn);
        }

        /// Send to a single key — convenience for "user_id → 1 conn" hubs.
        /// If multiple conns are registered to the same key, all receive.
        pub fn sendTo(self: *Self, key: Key, payload: []const u8) !void {
            return self.broadcast(key, payload);
        }

        /// Number of distinct keys (rooms / users) currently tracked.
        pub fn roomCount(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.rooms.count();
        }
    };
}

fn WorkersStub(comptime Key: type) type {
    return struct {
        const Self = @This();
        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}
        pub fn attach(_: *Self, _: Key, _: *anyopaque) !void {}
        pub fn detach(_: *Self, _: Key, _: *anyopaque) void {}
        pub fn broadcast(_: *Self, _: Key, _: []const u8) !void {}
        pub fn sendTo(_: *Self, _: Key, _: []const u8) !void {}
        pub fn roomCount(_: *Self) usize {
            return 0;
        }
    };
}
