//! Static database dispatch and Zig-side SQL shape validation.
const std = @import("std");

/// Specialize calls for a concrete backend value. Backend methods are called
/// directly and can be inlined; the portable `Db` VTable remains available.
pub fn Database(comptime Backend: type) type {
    return struct {
        backend: Backend,

        pub fn prepare(self: *@This(), sql: []const u8) @TypeOf(self.backend.prepare(sql)) {
            return self.backend.prepare(sql);
        }
        pub fn exec(self: *@This(), sql: []const u8) !void {
            return self.backend.exec(sql);
        }
        pub fn close(self: *@This()) void {
            return self.backend.close();
        }
    };
}

/// Compile-time SQL descriptor. It validates only facts available from the
/// query text and Zig types; it deliberately does not pretend to know the
/// deployed database schema.
pub fn Query(comptime sql: []const u8, comptime Args: type, comptime Row: type) type {
    validateArgs(sql, Args);
    validateRow(Row);
    return struct {
        pub const text = sql;
        pub const ArgsType = Args;
        pub const RowType = Row;
        pub const placeholder_count = countPlaceholders(sql);
    };
}

fn validateArgs(comptime sql: []const u8, comptime Args: type) void {
    const info = @typeInfo(Args);
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("SQL Args must be a tuple type");
    if (info.@"struct".fields.len != countPlaceholders(sql)) @compileError("SQL placeholder count does not match Args tuple length");
    inline for (info.@"struct".fields) |field| validateScalar(field.type, "SQL argument");
}

fn validateRow(comptime Row: type) void {
    if (Row == void) return;
    const info = @typeInfo(Row);
    if (info != .@"struct") @compileError("SQL Row must be a struct or void");
    inline for (info.@"struct".fields) |field| validateScalar(field.type, "SQL result field");
}

fn validateScalar(comptime T: type, comptime what: []const u8) void {
    const U = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    switch (@typeInfo(U)) {
        .int, .float, .bool => {},
        .pointer => |p| if (p.size != .slice or p.child != u8) @compileError(what ++ " has unsupported type " ++ @typeName(T)),
        else => @compileError(what ++ " has unsupported type " ++ @typeName(T)),
    }
}

fn countPlaceholders(comptime sql: []const u8) usize {
    comptime var count: usize = 0;
    comptime var quote: ?u8 = null;
    comptime var i: usize = 0;
    inline while (i < sql.len) : (i += 1) {
        const ch = sql[i];
        if (quote) |q| {
            if (ch == q) quote = null;
        } else if (ch == '\'' or ch == '"') {
            quote = ch;
        } else if (ch == '?') {
            count += 1;
        }
    }
    return count;
}

test "query validates Zig-visible SQL shape" {
    const Q = Query("select id, name from users where id = ?", std.meta.Tuple(&.{u64}), struct { id: u64, name: []const u8 });
    try std.testing.expectEqual(@as(usize, 1), Q.placeholder_count);
}
