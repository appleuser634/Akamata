//! Small, explicit SELECT builder. JOINs and complex predicates remain raw SQL.
const std = @import("std");
const db = @import("../db/db.zig");
const mapper = @import("row_mapper.zig");

pub const Order = enum { asc, desc };

pub const Query = struct {
    database: db.Db,
    allocator: std.mem.Allocator,
    table: []const u8,
    columns: []const u8,
    predicates: std.ArrayList(u8) = .empty,
    values: std.ArrayList(db.Value) = .empty,
    order_sql: ?[]const u8 = null,
    limit_value: ?usize = null,
    offset_value: ?usize = null,

    pub fn init(database: db.Db, allocator: std.mem.Allocator, table: []const u8, columns: []const u8) !Query {
        try identifier(table);
        return .{ .database = database, .allocator = allocator, .table = table, .columns = columns };
    }

    pub fn deinit(self: *Query) void {
        self.predicates.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    pub fn whereEq(self: *Query, column: []const u8, value: anytype) !*Query {
        try identifier(column);
        try self.andPrefix();
        try self.predicates.appendSlice(self.allocator, column);
        try self.predicates.appendSlice(self.allocator, " = ?");
        try self.appendValue(db.Value.fromAny(value));
        return self;
    }

    pub fn whereIn(self: *Query, column: []const u8, values: anytype) !*Query {
        try identifier(column);
        try self.andPrefix();
        try self.predicates.appendSlice(self.allocator, column);
        if (values.len == 0) {
            try self.predicates.appendSlice(self.allocator, " IN (SELECT 1 WHERE 0)");
            return self;
        }
        try self.predicates.appendSlice(self.allocator, " IN (");
        for (values, 0..) |value, i| {
            if (i > 0) try self.predicates.appendSlice(self.allocator, ", ");
            try self.predicates.append(self.allocator, '?');
            try self.appendValue(db.Value.fromAny(value));
        }
        try self.predicates.append(self.allocator, ')');
        return self;
    }

    pub fn orderBy(self: *Query, column: []const u8, direction: Order) !*Query {
        try identifier(column);
        self.order_sql = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ column, if (direction == .asc) "ASC" else "DESC" });
        return self;
    }

    pub fn limit(self: *Query, value: usize) *Query {
        self.limit_value = value;
        return self;
    }
    pub fn offset(self: *Query, value: usize) *Query {
        self.offset_value = value;
        return self;
    }

    pub fn sql(self: Query) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.allocator, "SELECT ");
        try out.appendSlice(self.allocator, self.columns);
        try out.appendSlice(self.allocator, " FROM ");
        try out.appendSlice(self.allocator, self.table);
        if (self.predicates.items.len > 0) {
            try out.appendSlice(self.allocator, " WHERE ");
            try out.appendSlice(self.allocator, self.predicates.items);
        }
        if (self.order_sql) |order| {
            try out.appendSlice(self.allocator, " ORDER BY ");
            try out.appendSlice(self.allocator, order);
        }
        if (self.limit_value) |n| {
            const text = try std.fmt.allocPrint(self.allocator, " LIMIT {d}", .{n});
            try out.appendSlice(self.allocator, text);
        }
        if (self.offset_value) |n| {
            const text = try std.fmt.allocPrint(self.allocator, " OFFSET {d}", .{n});
            try out.appendSlice(self.allocator, text);
        }
        return out.toOwnedSlice(self.allocator);
    }

    pub fn fetchAll(self: Query, comptime T: type) ![]T {
        const statement = try self.sql();
        var stmt = try self.database.prepare(statement);
        defer stmt.deinit();
        for (self.values.items, 0..) |value, i| try stmt.bind(i + 1, value);
        return mapper.all(T, self.allocator, &stmt);
    }

    fn andPrefix(self: *Query) !void {
        if (self.predicates.items.len > 0) try self.predicates.appendSlice(self.allocator, " AND ");
    }

    fn appendValue(self: *Query, value: db.Value) !void {
        const owned: db.Value = switch (value) {
            .text => |bytes| .{ .text = try self.allocator.dupe(u8, bytes) },
            .blob => |bytes| .{ .blob = try self.allocator.dupe(u8, bytes) },
            else => value,
        };
        try self.values.append(self.allocator, owned);
    }
};

fn identifier(value: []const u8) !void {
    if (value.len == 0) return error.InvalidIdentifier;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return error.InvalidIdentifier;
}
