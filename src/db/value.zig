const std = @import("std");

pub const Value = union(enum) {
    null_value: void,
    int: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,

    pub fn fromAny(v: anytype) Value {
        const T = @TypeOf(v);
        const info = @typeInfo(T);
        return switch (info) {
            .null => .{ .null_value = {} },
            .int, .comptime_int => .{ .int = @intCast(v) },
            .float, .comptime_float => .{ .float = @floatCast(v) },
            .bool => .{ .int = if (v) 1 else 0 },
            .optional => if (v) |inner| Value.fromAny(inner) else .{ .null_value = {} },
            .pointer => |p| switch (p.size) {
                .slice => if (p.child == u8) .{ .text = v } else @compileError("Value.fromAny: unsupported slice element"),
                .one => Value.fromAny(v.*),
                else => @compileError("Value.fromAny: unsupported pointer size"),
            },
            .array => if (info.array.child == u8) .{ .text = &v } else @compileError("Value.fromAny: unsupported array"),
            .@"enum" => .{ .int = @intFromEnum(v) },
            else => @compileError("Value.fromAny: unsupported type " ++ @typeName(T)),
        };
    }
};
