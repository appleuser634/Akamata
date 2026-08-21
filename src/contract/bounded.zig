//! Bounded wire types. Their limits are available to validation, schema and
//! client generators without adding runtime reflection or heap allocation.
const std = @import("std");

pub fn FixedBytes(comptime size: usize) type {
    return struct {
        pub const contract_kind = .fixed_bytes;
        pub const max_len = size;
        bytes: [size]u8,

        pub fn init(bytes: []const u8) !@This() {
            if (bytes.len != size) return error.InvalidLength;
            return .{ .bytes = bytes[0..size].* };
        }

        pub fn slice(self: *const @This()) []const u8 {
            return &self.bytes;
        }
    };
}

pub fn BoundedString(comptime capacity: usize) type {
    return struct {
        pub const contract_kind = .bounded_string;
        pub const max_len = capacity;
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn init(value: []const u8) !@This() {
            if (value.len > capacity) return error.TooLong;
            var out: @This() = .{};
            @memcpy(out.bytes[0..value.len], value);
            out.len = value.len;
            return out;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub fn BoundedSlice(comptime T: type, comptime capacity: usize) type {
    return struct {
        pub const contract_kind = .bounded_slice;
        pub const Element = T;
        pub const max_len = capacity;
        items: [capacity]T = undefined,
        len: usize = 0,

        pub fn init(value: []const T) !@This() {
            if (value.len > capacity) return error.TooLong;
            var out: @This() = .{};
            @memcpy(out.items[0..value.len], value);
            out.len = value.len;
            return out;
        }

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }
    };
}

test "bounded values reject overflow without allocating" {
    const S = BoundedString(4);
    const s = try S.init("zig");
    try std.testing.expectEqualStrings("zig", s.slice());
    try std.testing.expectError(error.TooLong, S.init("akamata"));
}
