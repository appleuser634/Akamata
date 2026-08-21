//! Platform-neutral realtime rooms. Backends own connections and transport;
//! application code only sees room/session operations and typed events.
const std = @import("std");
const events = @import("events.zig");

pub const ConnectionId = u64;
pub const Error = error{ NotFound, Closed, Backpressure, Unsupported, BackendFailure };
pub const Close = struct { code: u16 = 1000, reason: []const u8 = "closed" };

pub const ConnectionInfo = struct {
    id: ConnectionId,
    logical_identity: ?[]const u8 = null,
    metadata_json: []const u8 = "{}",
    connected_at_ms: i64,
    last_seen_ms: i64,
};

/// Result of application authentication + room authorization. `room` and
/// `logical_identity` are derived by trusted application code, never copied
/// from client query parameters.
pub fn AuthorizedConnection(comptime Principal: type) type {
    return struct {
        principal: Principal,
        room: []const u8,
        logical_identity: []const u8,
        metadata_json: []const u8 = "{}",
    };
}

pub fn Authorizer(comptime Principal: type) type {
    return struct {
        ptr: ?*anyopaque = null,
        authorize_fn: *const fn (?*anyopaque, []const u8, ?[]const u8) anyerror!AuthorizedConnection(Principal),

        pub fn authorize(self: @This(), credential: []const u8, requested_resource: ?[]const u8) !AuthorizedConnection(Principal) {
            return self.authorize_fn(self.ptr, credential, requested_resource);
        }
    };
}

pub fn InboundContext(comptime Principal: type) type {
    return struct {
        connection_id: ConnectionId,
        principal: Principal,
        logical_identity: []const u8,
        room: []const u8,
        metadata_json: []const u8 = "{}",
        correlation_id: ?[]const u8 = null,
    };
}

/// Explicit effects available to inbound application handlers. No inbound
/// event is forwarded unless the handler invokes one of these operations.
pub fn Responder(comptime Protocol: type) type {
    return struct {
        room_handle: Room(Protocol),
        allocator: std.mem.Allocator,
        sender: ConnectionId,

        pub fn direct(self: @This(), connection: ConnectionId, event: Protocol.Events) !void {
            return self.room_handle.send(self.allocator, connection, event);
        }
        pub fn broadcast(self: @This(), event: Protocol.Events) !usize {
            return self.room_handle.broadcast(self.allocator, event);
        }
        pub fn broadcastExceptSender(self: @This(), event: Protocol.Events) !usize {
            return self.room_handle.broadcastExcept(self.allocator, event, self.sender);
        }
        pub fn disconnect(self: @This(), connection: ConnectionId, close: Close) !void {
            return self.room_handle.disconnectWithReason(connection, close);
        }
    };
}

pub fn InboundHandler(comptime Protocol: type, comptime Principal: type) type {
    return *const fn (InboundContext(Principal), Protocol.Events, Responder(Protocol)) anyerror!void;
}

pub fn handleInbound(
    comptime Protocol: type,
    comptime Principal: type,
    allocator: std.mem.Allocator,
    service: Service,
    context: InboundContext(Principal),
    bytes: []const u8,
    max_message_bytes: usize,
    handler: InboundHandler(Protocol, Principal),
) !void {
    if (bytes.len > max_message_bytes) return error.MessageTooLarge;
    const event = try Protocol.decode(allocator, bytes);
    const room_handle = service.room(Protocol, context.room);
    return handler(context, event, .{ .room_handle = room_handle, .allocator = allocator, .sender = context.connection_id });
}

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
        disconnect: *const fn (*anyopaque, []const u8, ConnectionId, Close) Error!void,
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

        pub fn broadcastExcept(self: @This(), allocator: std.mem.Allocator, event: Protocol.Events, excluded: ConnectionId) !usize {
            const bytes = try Protocol.encode(allocator, event, .{});
            defer allocator.free(bytes);
            return self.backend.vtable.broadcast(self.backend.ptr, self.id, bytes, excluded);
        }

        pub fn disconnect(self: @This(), connection: ConnectionId, code: u16) !void {
            return self.disconnectWithReason(connection, .{ .code = code });
        }

        pub fn disconnectWithReason(self: @This(), connection: ConnectionId, close: Close) !void {
            return self.backend.vtable.disconnect(self.backend.ptr, self.id, connection, close);
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
    pub const CloseFn = *const fn (?*anyopaque, Close) void;
    const Entry = struct { room: []u8, identity: ?[]u8, ctx: ?*anyopaque, send_fn: SendFn, close_fn: ?CloseFn };

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
        return self.connectTransport(room_id, id, identity, ctx, send_fn, null);
    }

    pub fn connectTransport(self: *Native, room_id: []const u8, id: ConnectionId, identity: ?[]const u8, ctx: ?*anyopaque, send_fn: SendFn, close_fn: ?CloseFn) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connections.contains(id)) return error.BackendFailure;
        const room_copy = try self.allocator.dupe(u8, room_id);
        errdefer self.allocator.free(room_copy);
        const identity_copy = if (identity) |v| try self.allocator.dupe(u8, v) else null;
        try self.connections.put(id, .{ .room = room_copy, .identity = identity_copy, .ctx = ctx, .send_fn = send_fn, .close_fn = close_fn });
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
        const entry = self.connections.get(id) orelse {
            self.mutex.unlock();
            return error.NotFound;
        };
        if (!std.mem.eql(u8, entry.room, room)) {
            self.mutex.unlock();
            return error.NotFound;
        }
        const callback = entry.send_fn;
        const context = entry.ctx;
        self.mutex.unlock();
        return callback(context, bytes);
    }
    fn broadcast(ptr: *anyopaque, room: []const u8, bytes: []const u8, except: ?ConnectionId) Error!usize {
        const self: *Native = @ptrCast(@alignCast(ptr));
        const Target = struct { ctx: ?*anyopaque, send_fn: SendFn };
        var stack_targets: [128]Target = undefined;
        var heap_targets: ?[]Target = null;
        defer if (heap_targets) |items| self.allocator.free(items);
        self.mutex.lock();
        var count: usize = 0;
        var first_pass = self.connections.iterator();
        while (first_pass.next()) |entry| {
            if (except == entry.key_ptr.* or !std.mem.eql(u8, entry.value_ptr.room, room)) continue;
            if (count < stack_targets.len) stack_targets[count] = .{ .ctx = entry.value_ptr.ctx, .send_fn = entry.value_ptr.send_fn };
            count += 1;
        }
        const targets = if (count <= stack_targets.len) stack_targets[0..count] else blk: {
            const allocated = self.allocator.alloc(Target, count) catch {
                self.mutex.unlock();
                return error.Backpressure;
            };
            heap_targets = allocated;
            var index: usize = 0;
            var second_pass = self.connections.iterator();
            while (second_pass.next()) |entry| {
                if (except == entry.key_ptr.* or !std.mem.eql(u8, entry.value_ptr.room, room)) continue;
                allocated[index] = .{ .ctx = entry.value_ptr.ctx, .send_fn = entry.value_ptr.send_fn };
                index += 1;
            }
            break :blk allocated;
        };
        self.mutex.unlock();
        var delivered: usize = 0;
        for (targets) |target| {
            target.send_fn(target.ctx, bytes) catch continue;
            delivered += 1;
        }
        return delivered;
    }
    fn disconnect(ptr: *anyopaque, room: []const u8, id: ConnectionId, close: Close) Error!void {
        const self: *Native = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        const current = self.connections.get(id) orelse {
            self.mutex.unlock();
            return error.NotFound;
        };
        if (!std.mem.eql(u8, current.room, room)) {
            self.mutex.unlock();
            return error.NotFound;
        }
        const entry = self.connections.fetchRemove(id).?.value;
        self.mutex.unlock();
        defer self.allocator.free(entry.room);
        defer if (entry.identity) |identity| self.allocator.free(identity);
        if (entry.close_fn) |close_fn| close_fn(entry.ctx, close);
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
        closed: bool = false,
        close_code: u16 = 0,
        fn send(ptr: ?*anyopaque, _: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.count += 1;
        }
        fn close(ptr: ?*anyopaque, details: Close) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.closed = true;
            self.close_code = details.code;
        }
    };
    var native = Native.init(std.testing.allocator);
    defer native.deinit();
    var a: Sink = .{};
    var b: Sink = .{};
    try native.connectTransport("r1", 1, "device", &a, Sink.send, Sink.close);
    try native.connect("r1", 2, "device", &b, Sink.send);
    const room = native.service().room(P, "r1");
    try room.send(std.testing.allocator, 1, .{ .signal = .{ .value = 1 } });
    try std.testing.expectEqual(@as(usize, 2), try room.broadcast(std.testing.allocator, .{ .signal = .{ .value = 2 } }));
    try std.testing.expectEqual(@as(usize, 2), room.presence().connections);
    try std.testing.expectEqual(@as(usize, 1), room.presence().members);
    _ = try room.broadcastExcept(std.testing.allocator, .{ .signal = .{ .value = 3 } }, 1);
    try std.testing.expectEqual(@as(usize, 2), a.count);
    try std.testing.expectEqual(@as(usize, 2), b.count);
    try room.disconnectWithReason(1, .{ .code = 4001, .reason = "authorization revoked" });
    try std.testing.expect(a.closed);
    try std.testing.expectEqual(@as(u16, 4001), a.close_code);
    try std.testing.expectEqual(@as(usize, 1), room.presence().connections);
}

test "inbound events always pass through application handler" {
    const Payload = struct { value: u8 };
    const E = union(enum) { signal: Payload };
    const P = events.Protocol(E, 1);
    const Principal = union(enum) { client: u64 };
    const Sink = struct {
        count: usize = 0,
        fn send(ptr: ?*anyopaque, _: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.count += 1;
        }
    };
    const Handler = struct {
        fn handle(ctx: InboundContext(Principal), event: E, responder: Responder(P)) !void {
            try std.testing.expectEqual(@as(ConnectionId, 1), ctx.connection_id);
            try std.testing.expectEqual(@as(u8, 7), event.signal.value);
            _ = try responder.broadcastExceptSender(.{ .signal = .{ .value = 8 } });
        }
    };
    var native = Native.init(std.testing.allocator);
    defer native.deinit();
    var sender: Sink = .{};
    var peer: Sink = .{};
    try native.connect("authorized-room", 1, "client:9", &sender, Sink.send);
    try native.connect("authorized-room", 2, "client:9", &peer, Sink.send);
    const bytes = try P.encode(std.testing.allocator, .{ .signal = .{ .value = 7 } }, .{});
    defer std.testing.allocator.free(bytes);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try handleInbound(P, Principal, arena_state.allocator(), native.service(), .{
        .connection_id = 1,
        .principal = .{ .client = 9 },
        .logical_identity = "client:9",
        .room = "authorized-room",
    }, bytes, 1024, Handler.handle);
    try std.testing.expectEqual(@as(usize, 0), sender.count);
    try std.testing.expectEqual(@as(usize, 1), peer.count);
    try std.testing.expectError(error.MessageTooLarge, handleInbound(P, Principal, arena_state.allocator(), native.service(), .{
        .connection_id = 1,
        .principal = .{ .client = 9 },
        .logical_identity = "client:9",
        .room = "authorized-room",
    }, bytes, 1, Handler.handle));
}

test "native transport callbacks execute outside registry lock" {
    const E = union(enum) { ping: struct {} };
    const P = events.Protocol(E, 1);
    const Callback = struct {
        service: Service,
        observed: usize = 0,
        fn send(raw: ?*anyopaque, _: []const u8) Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            // Re-entering presence would deadlock if send ran under the map lock.
            self.observed = self.service.room(P, "room").presence().connections;
        }
    };
    var native = Native.init(std.testing.allocator);
    defer native.deinit();
    var callback = Callback{ .service = native.service() };
    try native.connect("room", 1, "client", &callback, Callback.send);
    try callback.service.room(P, "room").send(std.testing.allocator, 1, .{ .ping = .{} });
    try std.testing.expectEqual(@as(usize, 1), callback.observed);
}
