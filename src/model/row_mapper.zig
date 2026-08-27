//! Shared positional SQL row mapper used by repositories, relations and DTO queries.
const std = @import("std");
const db = @import("../db/db.zig");
const schema = @import("schema.zig");

pub fn read(comptime T: type, allocator: std.mem.Allocator, stmt: db.Stmt) !T {
    if (@typeInfo(T) != .@"struct") @compileError("row mapper expects a struct DTO");
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, index| {
        @field(out, field.name) = try readField(T, field.name, field.type, allocator, stmt, index);
    }
    return out;
}

fn readField(comptime Owner: type, comptime name: []const u8, comptime T: type, allocator: std.mem.Allocator, stmt: db.Stmt, index: usize) !T {
    if (@typeInfo(T) == .optional) {
        if (try stmt.columnIsNull(index)) return null;
        return try readField(Owner, name, @typeInfo(T).optional.child, allocator, stmt, index);
    }
    return switch (@typeInfo(T)) {
        .int => @intCast(try stmt.columnInt(index)),
        .float => @floatCast(try stmt.columnFloat(index)),
        .bool => (try stmt.columnInt(index)) != 0,
        .@"enum" => if (@hasDecl(Owner, "__schema") and comptime schema.enumStringsLookup(Owner, name) != null)
            try schema.enumFromText(Owner, name, T, try stmt.columnText(index))
        else
            @enumFromInt(try stmt.columnInt(index)),
        .pointer => |p| if (p.size == .slice and p.child == u8)
            try allocator.dupe(u8, try stmt.columnText(index))
        else
            @compileError("row mapper: unsupported pointer field " ++ name),
        else => @compileError("row mapper: unsupported field " ++ name ++ " of type " ++ @typeName(T)),
    };
}

pub fn all(comptime T: type, allocator: std.mem.Allocator, stmt: *db.Stmt) ![]T {
    var rows: std.ArrayList(T) = .empty;
    while ((try stmt.step()) == .row) try rows.append(allocator, try read(T, allocator, stmt.*));
    return rows.toOwnedSlice(allocator);
}

pub fn fetchAll(comptime T: type, database: db.Db, allocator: std.mem.Allocator, sql: []const u8, args: anytype) ![]T {
    var stmt = try database.prepare(sql);
    defer stmt.deinit();
    try stmt.bindAll(args);
    return all(T, allocator, &stmt);
}
