// application/x-www-form-urlencoded parser.

const std = @import("std");

pub const FormError = error{
    InvalidEscape,
    OutOfMemory,
};

pub const Field = struct { name: []const u8, value: []const u8 };

pub const Form = struct {
    fields: []const Field,

    pub fn get(self: Form, name: []const u8) ?[]const u8 {
        for (self.fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    pub fn all(self: Form, arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (self.fields) |f| if (std.mem.eql(u8, f.name, name)) try out.append(arena, f.value);
        return out.toOwnedSlice(arena);
    }
};

/// Parse `key1=val1&key2=val2&...` (RFC 3986 percent-decoded, `+` → space).
/// All `Field` slices are allocated in `arena`.
pub fn parse(arena: std.mem.Allocator, body: []const u8) FormError!Form {
    var out: std.ArrayList(Field) = .empty;
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const name_raw = if (eq) |e| pair[0..e] else pair;
        const value_raw = if (eq) |e| pair[e + 1 ..] else "";
        const name = try decode(arena, name_raw);
        const value = try decode(arena, value_raw);
        try out.append(arena, .{ .name = name, .value = value });
    }
    return .{ .fields = try out.toOwnedSlice(arena) };
}

fn decode(arena: std.mem.Allocator, s: []const u8) FormError![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+') {
            try buf.append(arena, ' ');
        } else if (c == '%') {
            if (i + 2 >= s.len) return FormError.InvalidEscape;
            const hi = hex(s[i + 1]) orelse return FormError.InvalidEscape;
            const lo = hex(s[i + 2]) orelse return FormError.InvalidEscape;
            try buf.append(arena, (hi << 4) | lo);
            i += 2;
        } else {
            try buf.append(arena, c);
        }
    }
    return buf.toOwnedSlice(arena);
}

fn hex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => null,
    };
}

test "parse basic key=value pairs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const form = try parse(arena, "name=alice&age=30");
    try std.testing.expectEqualStrings("alice", form.get("name").?);
    try std.testing.expectEqualStrings("30", form.get("age").?);
}

test "parse handles percent encoding and + as space" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const form = try parse(arena, "q=hello+world&path=%2Fusers%2F42");
    try std.testing.expectEqualStrings("hello world", form.get("q").?);
    try std.testing.expectEqualStrings("/users/42", form.get("path").?);
}

test "parse decodes UTF-8 escapes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const form = try parse(arena, "city=%E6%9D%B1%E4%BA%AC"); // 東京
    try std.testing.expectEqualStrings("東京", form.get("city").?);
}

test "all() returns repeated keys" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const form = try parse(arena, "tag=a&tag=b&tag=c");
    const tags = try form.all(arena, "tag");
    try std.testing.expectEqual(@as(usize, 3), tags.len);
    try std.testing.expectEqualStrings("a", tags[0]);
    try std.testing.expectEqualStrings("c", tags[2]);
}
