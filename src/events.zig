//! Transport-neutral typed events and realtime protocol metadata.
const std = @import("std");

pub const EventOptions = struct {
    name: ?[]const u8 = null,
    version: u16 = 1,
};

pub fn validateEventType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum" => {},
        .@"union" => |u| if (u.tag_type == null)
            @compileError("Akamata event unions must be tagged: " ++ @typeName(T)),
        else => @compileError("Akamata events must be structs, enums, or tagged unions: " ++ @typeName(T)),
    }
}

pub fn Descriptor(comptime T: type, comptime options: EventOptions) type {
    validateEventType(T);
    return struct {
        pub const Payload = T;
        pub const name = options.name orelse @typeName(T);
        pub const version = options.version;
        pub const type_id: u64 = stableId(name, version);

        pub fn encode(allocator: std.mem.Allocator, value: T) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            try std.json.Stringify.value(value, .{}, &aw.writer);
            return aw.toOwnedSlice();
        }

        pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
            return std.json.parseFromSlice(T, allocator, bytes, .{ .ignore_unknown_fields = true });
        }
    };
}

pub const EnvelopeMeta = struct {
    protocol_version: u16 = 1,
    event_type: []const u8,
    event_id: ?[]const u8 = null,
    correlation_id: ?[]const u8 = null,
    attempt: u16 = 1,
};

pub fn Envelope(comptime Payload: type) type {
    validateEventType(Payload);
    return struct {
        protocol_version: u16 = 1,
        event_type: []const u8,
        event_id: ?[]const u8 = null,
        correlation_id: ?[]const u8 = null,
        attempt: u16 = 1,
        payload: Payload,
    };
}

/// A tagged union is the protocol source of truth. Its tags become wire event
/// names and its payloads are shared by serializers and client generators.
pub fn Protocol(comptime EventUnion: type, comptime version: u16) type {
    validateProtocol(EventUnion);
    return struct {
        pub const Events = EventUnion;
        pub const protocol_version = version;
        pub const event_count = @typeInfo(EventUnion).@"union".fields.len;

        pub fn encode(allocator: std.mem.Allocator, event: EventUnion, meta: struct {
            event_id: ?[]const u8 = null,
            correlation_id: ?[]const u8 = null,
        }) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            const tag = @tagName(event);
            try aw.writer.writeAll("{\"protocol_version\":");
            try aw.writer.print("{d},\"event_type\":", .{version});
            try std.json.Stringify.value(tag, .{}, &aw.writer);
            if (meta.event_id) |id| {
                try aw.writer.writeAll(",\"event_id\":");
                try std.json.Stringify.value(id, .{}, &aw.writer);
            }
            if (meta.correlation_id) |id| {
                try aw.writer.writeAll(",\"correlation_id\":");
                try std.json.Stringify.value(id, .{}, &aw.writer);
            }
            try aw.writer.writeAll(",\"payload\":");
            switch (event) {
                inline else => |payload| try std.json.Stringify.value(payload, .{}, &aw.writer),
            }
            try aw.writer.writeByte('}');
            return aw.toOwnedSlice();
        }
    };
}

pub fn validateProtocol(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"union" or info.@"union".tag_type == null)
        @compileError("Akamata realtime protocols must be tagged unions");
    inline for (info.@"union".fields) |field| validateEventType(field.type);
}

pub fn stableId(comptime name: []const u8, comptime version: u16) u64 {
    var hash: u64 = 14695981039346656037;
    for (name) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    hash ^= @as(u8, @truncate(version));
    hash *%= 1099511628211;
    hash ^= @as(u8, @truncate(version >> 8));
    return hash *% 1099511628211;
}

test "event descriptor and versioned protocol" {
    const Created = struct { id: u64 };
    const Closed = struct { reason: []const u8 };
    const Event = union(enum) { created: Created, closed: Closed };
    const D = Descriptor(Created, .{ .name = "created", .version = 2 });
    try std.testing.expect(D.type_id != 0);
    const bytes = try Protocol(Event, 3).encode(std.testing.allocator, .{ .created = .{ .id = 42 } }, .{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"protocol_version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"event_type\":\"created\"") != null);
}
