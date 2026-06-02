// DDL generation from TableDef.
//
// Targets the SQLite/D1/Turso (libsql) dialect — they share enough of the
// grammar that one generator covers all three for our purposes:
//   - INTEGER PRIMARY KEY AUTOINCREMENT
//   - TEXT, INTEGER, REAL, BLOB type names
//   - CREATE TABLE [IF NOT EXISTS] / CREATE INDEX [IF NOT EXISTS]
//   - STRICT tables (opt-in, default on — catches type errors early)
//
// We deliberately don't try to support every variant of SQL here. If you
// need something exotic, write the migration SQL by hand and feed it to
// `am.db.execAll(@embedFile(...))` like before.

const std = @import("std");
const schema = @import("schema.zig");

pub const Options = struct {
    /// If true, emit `CREATE TABLE IF NOT EXISTS` (idempotent first-boot).
    if_not_exists: bool = true,
    /// If true, append `STRICT` to the table definition. SQLite/D1/libsql
    /// all support it. Highly recommended — silently coercing types is a
    /// classic SQLite footgun.
    strict: bool = true,
};

fn sqlNameFor(t: schema.SqlType) []const u8 {
    return switch (t) {
        .integer => "INTEGER",
        .real => "REAL",
        .text => "TEXT",
        .blob => "BLOB",
    };
}

/// Append one column's column-def clause to `buf`:
/// `name TYPE [NOT NULL] [DEFAULT (...)] [PRIMARY KEY AUTOINCREMENT]`.
fn appendColumn(buf: *std.ArrayList(u8), arena: std.mem.Allocator, col: schema.Column) !void {
    try buf.appendSlice(arena, col.sql_name);
    try buf.append(arena, ' ');
    try buf.appendSlice(arena, sqlNameFor(col.sql_type));
    if (col.primary_key) {
        // Convention: the ?i64 pk gets AUTOINCREMENT, which in SQLite means
        // monotonic + never-reuses-rowids. Cheap insurance against id
        // collisions across migration churn.
        if (col.sql_type == .integer) {
            try buf.appendSlice(arena, " PRIMARY KEY AUTOINCREMENT");
        } else {
            try buf.appendSlice(arena, " PRIMARY KEY");
        }
        // PRIMARY KEY already implies NOT NULL.
        return;
    }
    if (!col.nullable) try buf.appendSlice(arena, " NOT NULL");
    if (col.default_sql) |d| {
        try buf.appendSlice(arena, " DEFAULT (");
        try buf.appendSlice(arena, d);
        try buf.append(arena, ')');
    }
}

/// Generate `CREATE TABLE ...` SQL for the given TableDef, allocating from
/// `arena`. Caller owns the returned slice (free with `arena`).
pub fn createTable(arena: std.mem.Allocator, td: schema.TableDef, opts: Options) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);
    try buf.appendSlice(arena, "CREATE TABLE ");
    if (opts.if_not_exists) try buf.appendSlice(arena, "IF NOT EXISTS ");
    try buf.appendSlice(arena, td.table);
    try buf.appendSlice(arena, " (\n");
    for (td.columns, 0..) |c, i| {
        try buf.appendSlice(arena, "  ");
        try appendColumn(&buf, arena, c);
        if (i + 1 < td.columns.len) try buf.append(arena, ',');
        try buf.append(arena, '\n');
    }
    try buf.append(arena, ')');
    if (opts.strict) try buf.appendSlice(arena, " STRICT");
    return buf.toOwnedSlice(arena);
}

/// Generate one `CREATE [UNIQUE] INDEX ...` per Index in the TableDef.
/// Returns a slice of slices (each one is a complete SQL statement).
pub fn createIndexes(arena: std.mem.Allocator, td: schema.TableDef, opts: Options) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);
    for (td.indexes) |ix| {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(arena);
        try buf.appendSlice(arena, "CREATE ");
        if (ix.unique) try buf.appendSlice(arena, "UNIQUE ");
        try buf.appendSlice(arena, "INDEX ");
        if (opts.if_not_exists) try buf.appendSlice(arena, "IF NOT EXISTS ");
        try buf.appendSlice(arena, ix.name);
        try buf.appendSlice(arena, " ON ");
        try buf.appendSlice(arena, td.table);
        try buf.appendSlice(arena, " (");
        for (ix.columns, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(arena, ", ");
            try buf.appendSlice(arena, c);
        }
        try buf.append(arena, ')');
        try out.append(arena, try buf.toOwnedSlice(arena));
    }
    return out.toOwnedSlice(arena);
}

/// One-shot helper: emit `CREATE TABLE ...; CREATE INDEX ...;` as a single
/// `;`-joined string (suitable for `db.execAll`).
pub fn fullSchema(arena: std.mem.Allocator, td: schema.TableDef, opts: Options) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(arena);
    const create = try createTable(arena, td, opts);
    try buf.appendSlice(arena, create);
    try buf.appendSlice(arena, ";\n");
    const indexes = try createIndexes(arena, td, opts);
    for (indexes) |ix_sql| {
        try buf.appendSlice(arena, ix_sql);
        try buf.appendSlice(arena, ";\n");
    }
    return buf.toOwnedSlice(arena);
}

// === Tests ===

const testing = std.testing;

const User = struct {
    id: ?i64 = null,
    email: []const u8,
    name: []const u8,
    age: ?i32 = null,
    created_at: ?i64 = null,

    pub const __schema = .{
        .table = "users",
        .primary_key = "id",
        .indexes = .{
            .{ "email", .unique },
            .{ "name", .index },
        },
    };
};

test "createTable: User → expected SQL" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const td = comptime schema.tableDef(User);
    const sql = try createTable(arena, td, .{});
    const expected =
        "CREATE TABLE IF NOT EXISTS users (\n" ++
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n" ++
        "  email TEXT NOT NULL,\n" ++
        "  name TEXT NOT NULL,\n" ++
        "  age INTEGER,\n" ++
        "  created_at INTEGER\n" ++
        ") STRICT";
    try testing.expectEqualStrings(expected, sql);
}

test "createIndexes: emits one statement per index" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const td = comptime schema.tableDef(User);
    const stmts = try createIndexes(arena, td, .{});
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS users_email_unq ON users (email)",
        stmts[0],
    );
    try testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS users_name_idx ON users (name)",
        stmts[1],
    );
}

test "fullSchema: ; joined create + indexes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const td = comptime schema.tableDef(User);
    const sql = try fullSchema(arena, td, .{ .if_not_exists = true, .strict = true });
    try testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE IF NOT EXISTS users") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "CREATE UNIQUE INDEX IF NOT EXISTS users_email_unq") != null);
    try testing.expect(std.mem.indexOf(u8, sql, ") STRICT;") != null);
}

test "createTable: non-strict + no IF NOT EXISTS" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const td = comptime schema.tableDef(User);
    const sql = try createTable(arena, td, .{ .if_not_exists = false, .strict = false });
    try testing.expect(std.mem.startsWith(u8, sql, "CREATE TABLE users ("));
    try testing.expect(std.mem.endsWith(u8, sql, ")"));
}
