//! Platform-neutral realtime rooms. Backends own connections and transport;
//! application code only sees room/session operations and typed events.
const std = @import("std");
const events = @import("events.zig");

pub const ConnectionId = u64;
pub const Error = error{ NotFound, Closed, Backpressure, Unsupported, BackendFailure };

pub const ConnectionInfo = struct {
    id: ConnectionId,
    logical_identity: ?[]const u8 = null,
    metadata_json: []const u8 = "{}",
    connected_at_ms: i64,
    last_seen_ms: i64,
};

pub const Presence = struct {
    connections: usize,
    members: usize,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        direct: *const fn (*anyopaque, []const u8, ConnectionId, []const u8) Error!void,
        broadcast: *const fn (*anyopaque, []const u8, []const u8, ?ConnectionId) Error!usize,
        disconnect: *const fn (*anyopaque, []const u8, ConnectionId, u16) Error!void,
        presence: *const fn (*anyopaque, []const u8) Presence,
    };
};

pub const Service = struct {
    backend: Backend,

    pub fn room(self: Service, comptime Protocol: type, id: []const u8) Room(Protocol) {
        comptime events.validateProtocol(Protocol.Events);
        return .{ .backend = self.backend, .id = id };
    }
};

pub fn Room(comptime Protocol: type) type {
    return struct {
        backend: Backend,
        id: []const u8,

        pub fn send(self: @This(), allocator: std.mem.Allocator, connection: ConnectionId, event: Protocol.Events) !void {
            const bytes = try Protocol.encode(allocator, event, .{});
            defer allocator.free(bytes);
            return self.backend.vtable.direct(self.backend.ptr, self.id, connection, bytes);
        }

        pub fn broadcast(self: @This(), allocator: std.mem.Allocator, event: Protocol.Events) !usize {
            const bytes = try Protocol.encode(allocator, event, .{});
            defer allocator.free(bytes);
            return self.backend.vtable.broadcast(self.backend.ptr, self.id, bytes, null);
        }

        pub fn disconnect(self: @This(), connection: ConnectionId, code: u16) !void {
            return self.backend.vtable.disconnect(self.backend.ptr, self.id, connection, code);
        }

        pub fn presence(self: @This()) Presence {
            return self.backend.vtable.presence(self.backend.ptr, self.id);
        }
    };
}

/// Transport-independent native backend. The application/server supplies a
/// zero-allocation send callback when attaching each WebSocket connection.
pub const Native = struct {
    allocator: std.mem.Allocator,
    mutex: @import("sync.zig").Mutex,
    connections: std.AutoHashMap(ConnectionId, Entry),

    pub const SendFn = *const fn (?*anyopaque, []const u8) Error!void;
    const Entry = struct { room: []u8, identity: ?[]u8, ctx: ?*anyopaque, send_fn: SendFn };

    pub fn init(allocator: std.mem.Allocator) Native {
        return .{ .allocator = allocator, .mutex = .init(), .connections = .init(allocator) };
    }
    pub fn deinit(self: *Native) void {
        var it = self.connections.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.room);
            if (entry.identity) |v| self.allocator.free(v);
        }
        self.connections.deinit();
        self.mutex.deinit();
    }
    pub fn service(self: *Native) Service {
        return .{ .backend = .{ .ptr = self, .vtable = &vtable } };
    }

    pub fn connect(self: *Native, room_id: []const u8, id: ConnectionId, identity: ?[]const u8, ctx: ?*anyopaque, send_fn: SendFn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connections.contains(id)) return error.BackendFailure;
        const room_copy = try self.allocator.dupe(u8, room_id);
        errdefer self.allocator.free(room_copy);
        const identity_copy = if (identity) |v| try self.allocator.dupe(u8, v) else null;
        try self.connections.put(id, .{ .room = room_copy, .identity = identity_copy, .ctx = ctx, .send_fn = send_fn });
    }

    pub fn detach(self: *Native, id: ConnectionId) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connections.fetchRemove(id)) |removed| {
            self.allocator.free(removed.value.room);
            if (removed.value.identity) |v| self.allocator.free(v);
        }
    }

    const vtable: Backend.VTable = .{ .direct = direct, .broadcast = broadcast, .disconnect = disconnect, .presence = getPresence };
    fn direct(ptr: *anyopaque, room: []const u8, id: ConnectionId, bytes: []const u8) Error!void {
        const self: *Native = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.connections.get(id) orelse return error.NotFound;
        if (!std.mem.eql(u8, entry.room, room)) return error.NotFound;
        return entry.send_fn(entry.ctx, bytes);
    }
    fn broadcast(ptr: *anyopaque, room: []const u8, bytes: []const u8, except: ?ConnectionId) Error!usize {
        const self: *Native = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        var sent: usize = 0;
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (except == entry.key_ptr.* or !std.mem.eql(u8, entry.value_ptr.room, room)) continue;
            try entry.value_ptr.send_fn(entry.value_ptr.ctx, bytes);
            sent += 1;
        }
        return sent;
    }
    fn disconnect(ptr: *anyopaque, room: []const u8, id: ConnectionId, _: u16) Error!void {
        const self: *Native = @ptrCast(@alignCast(ptr));
        const entry = self.connections.get(id) orelse return error.NotFound;
        if (!std.mem.eql(u8, entry.room, room)) return error.NotFound;
        self.detach(id);
    }
    fn getPresence(ptr: *anyopaque, room: []const u8) Presence {
        const self: *Native = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var identities = std.StringHashMap(void).init(self.allocator);
        defer identities.deinit();
        var it = self.connections.valueIterator();
        while (it.next()) |entry| if (std.mem.eql(u8, entry.room, room)) {
            count += 1;
            if (entry.identity) |identity| identities.put(identity, {}) catch {};
        };
        return .{ .connections = count, .members = identities.count() };
    }
};

test "native room isolation, direct send, broadcast and presence" {
    const Payload = struct { value: u8 };
    const E = union(enum) { signal: Payload };
    const P = events.Protocol(E, 1);
    const Sink = struct {
        count: usize = 0,
        fn send(ptr: ?*anyopaque, _: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.count += 1;
        }
    };
    var native = Native.init(std.testing.allocator);
    defer native.deinit();
    var a: Sink = .{};
    var b: Sink = .{};
    try native.connect("r1", 1, "device", &a, Sink.send);
    try native.connect("r1", 2, "device", &b, Sink.send);
    const room = native.service().room(P, "r1");
    try room.send(std.testing.allocator, 1, .{ .signal = .{ .value = 1 } });
    try std.testing.expectEqual(@as(usize, 2), try room.broadcast(std.testing.allocator, .{ .signal = .{ .value = 2 } }));
    try std.testing.expectEqual(@as(usize, 2), room.presence().connections);
    try std.testing.expectEqual(@as(usize, 1), room.presence().members);
}
