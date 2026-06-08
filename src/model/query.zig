// Active-Record-style query API built on top of `am.db.Db`.
//
// Usage:
//
//     const User = struct { ... };
//     const Users = am.model.repo(User);
//
//     const u = try Users.find(db, arena, 7);            // ?User
//     const all = try Users.all(db, arena);              // []User
//     const adults = try Users.where(db, arena, .{ .age = 18 });
//     var u2 = try Users.create(db, .{ .email = "x", .name = "x" });
//     u2.name = "renamed";
//     try Users.save(db, &u2);
//     try Users.delete(db, u2.id.?);
//
// Strings in the returned values are owned by the arena you pass in (or
// duplicated into the supplied allocator for single-row returns); the row
// memory from the backend is *not* aliased.
//
// `where(.{...})` accepts a struct of field=value pairs and ANDs them
// together. For everything more complex (JOIN, OR, LIKE, ...) drop down to
// raw `am.db.Db`.

const std = @import("std");
const db_mod = @import("../db/db.zig");
const schema_mod = @import("schema.zig");
const validate_mod = @import("validate.zig");

pub fn Repo(comptime T: type) type {
    return struct {
        pub const Model = T;
        pub const table_def: schema_mod.TableDef = schema_mod.tableDef(T);

        // ===== read =====

        /// `SELECT ... WHERE id = ? LIMIT 1`. Returns null when no row.
        pub fn find(database: db_mod.Db, arena: std.mem.Allocator, id: i64) !?T {
            const sql = try buildSelect(arena, " WHERE " ++ pk_sql_name ++ " = ? LIMIT 1");
            var stmt = try database.prepare(sql);
            defer stmt.deinit();
            try stmt.bindAll(.{id});
            const step = try stmt.step();
            if (step == .done) return null;
            return try readRowDupe(arena, stmt);
        }

        /// `SELECT ... ORDER BY <pk> DESC`.
        pub fn all(database: db_mod.Db, arena: std.mem.Allocator) ![]T {
            const sql = try buildSelect(arena, " ORDER BY " ++ pk_sql_name ++ " DESC");
            return try fetchAll(database, arena, sql, .{});
        }

        /// `SELECT ... WHERE k1 = ? AND k2 = ? ...`. Pass an anonymous
        /// struct literal whose field names match columns.
        pub fn where(database: db_mod.Db, arena: std.mem.Allocator, conds: anytype) ![]T {
            const Conds = @TypeOf(conds);
            const ci = @typeInfo(Conds);
            if (ci != .@"struct") @compileError("where: expected anon struct, got " ++ @typeName(Conds));
            const fields = ci.@"struct".fields;

            var sql_buf: std.ArrayList(u8) = .empty;
            errdefer sql_buf.deinit(arena);
            try sql_buf.appendSlice(arena, comptime selectClause());
            if (fields.len > 0) try sql_buf.appendSlice(arena, " WHERE ");
            inline for (fields, 0..) |f, i| {
                if (i > 0) try sql_buf.appendSlice(arena, " AND ");
                // Translate the Zig-side condition field name to its SQL name.
                try sql_buf.appendSlice(arena, comptime fieldSqlName(f.name));
                try sql_buf.appendSlice(arena, " = ?");
            }
            try sql_buf.appendSlice(arena, " ORDER BY ");
            try sql_buf.appendSlice(arena, pk_sql_name);
            try sql_buf.appendSlice(arena, " DESC");
            const sql = try sql_buf.toOwnedSlice(arena);

            // Convert struct fields into a tuple of Values via Value.fromAny.
            return try fetchAllStruct(database, arena, sql, conds);
        }

        // ===== write =====

        /// Validate the value (if `__schema.validates` exists). Returns the
        /// list of errors; empty = OK. Re-exported here so callers can do
        /// `try Users.validate(user, arena)` symmetrically with the other
        /// repo methods.
        pub fn validate(value: T, arena: std.mem.Allocator) ![]validate_mod.ValidationError {
            return validate_mod.validate(T, value, arena);
        }

        /// INSERT with RETURNING. Fields whose value is null AND have a
        /// default (e.g. `id`, `created_at`) are *omitted* from the column
        /// list so the DB applies its own default. Returned row's string
        /// fields are duplicated into `arena`.
        pub fn create(database: db_mod.Db, arena: std.mem.Allocator, value: T) !T {
            const sql = try buildInsert(arena, value);
            var stmt = try database.prepare(sql);
            defer stmt.deinit();
            try bindInsertArgs(&stmt, value);
            const r = try stmt.step();
            if (r != .row) return db_mod.DbError.NoRow;
            // RETURNING lists columns in declared order (see buildInsert), so
            // the row aligns with readRowDupe's positional struct mapping.
            return readRowDupe(arena, stmt);
        }

        /// `UPDATE ... WHERE id = ?`. Requires `value`'s primary key to be
        /// set. Uses `arena` for the SQL string only (the row itself is not
        /// re-read).
        pub fn save(database: db_mod.Db, arena: std.mem.Allocator, value: *T) !void {
            const pk_field = comptime findPkField();
            const pk_val: ?i64 = blk: {
                const v = @field(value.*, pk_field);
                if (@typeInfo(@TypeOf(v)) == .optional) break :blk if (v) |x| @intCast(x) else null;
                break :blk @intCast(v);
            };
            if (pk_val == null) return error.MissingPrimaryKey;

            const sql = try buildUpdate(arena);
            var stmt = try database.prepare(sql);
            defer stmt.deinit();
            try bindUpdateArgs(&stmt, value.*, pk_val.?);
            _ = try stmt.step();
        }

        /// Escape hatch: run arbitrary SQL and map each row into `T`. The
        /// SQL must `SELECT` the model's columns in declaration order — i.e.
        /// the same columns the framework's auto-generated SELECTs use. For
        /// joins/aggregates that don't fit `T`, drop down to `db.prepare()`.
        ///
        /// `args` is a tuple of values matching the `?` placeholders.
        pub fn queryRaw(
            database: db_mod.Db,
            arena: std.mem.Allocator,
            sql: []const u8,
            args: anytype,
        ) ![]T {
            return fetchAll(database, arena, sql, args);
        }

        /// Like `queryRaw`, but the caller prepares and binds the statement
        /// themselves. Use this when the placeholders are bound conditionally
        /// at runtime (e.g. an optional search filter) and so don't fit a
        /// fixed `args` tuple. The statement must already be stepped-to-ready
        /// (i.e. just prepared + bound); this drains all rows. The caller still
        /// owns the statement and must `deinit` it. Rows must SELECT the
        /// model's columns in declaration order, same as `queryRaw`.
        pub fn mapStmt(arena: std.mem.Allocator, stmt: db_mod.Stmt) ![]T {
            var out: std.ArrayList(T) = .empty;
            while ((try stmt.step()) == .row) {
                try out.append(arena, try readRowDupe(arena, stmt));
            }
            return out.toOwnedSlice(arena);
        }

        pub const RowsWithCount = struct { rows: []T, total: i64 };

        /// Like `mapStmt`, but reads a trailing window-aggregate column as a
        /// total row count, so a paginated SELECT can return its full match
        /// count in a single query (one D1 round-trip) instead of a separate
        /// `SELECT COUNT(*)`. The SQL must select the model's columns in
        /// declaration order followed by exactly one extra column carrying the
        /// total — e.g. `..., COUNT(*) OVER () FROM ... LIMIT ? OFFSET ?`.
        /// The total is read from each row (constant across the window); on an
        /// empty result the total is 0.
        pub fn mapStmtWithCount(arena: std.mem.Allocator, stmt: db_mod.Stmt) !RowsWithCount {
            const count_idx = @typeInfo(T).@"struct".fields.len; // 0-based: right after model columns
            var out: std.ArrayList(T) = .empty;
            var total: i64 = 0;
            while ((try stmt.step()) == .row) {
                try out.append(arena, try readRowDupe(arena, stmt));
                total = try stmt.columnInt(count_idx);
            }
            return .{ .rows = try out.toOwnedSlice(arena), .total = total };
        }

        /// `DELETE ... WHERE <pk> = ?`.
        pub fn delete(database: db_mod.Db, id: i64) !void {
            const sql = "DELETE FROM " ++ table_def.table ++ " WHERE " ++ pk_sql_name ++ " = ?";
            var stmt = try database.prepare(sql);
            defer stmt.deinit();
            try stmt.bindAll(.{id});
            _ = try stmt.step();
        }

        // ===== helpers =====

        /// Comma-separated column list in *struct declaration order* — the
        /// order `readRowDupe` reads results positionally. Used by both SELECT
        /// and `INSERT ... RETURNING` so the returned row always aligns with
        /// the struct, regardless of the table's physical column order (which
        /// can differ after `ALTER TABLE ADD COLUMN`).
        fn columnList() []const u8 {
            comptime var buf: []const u8 = "";
            comptime {
                for (table_def.columns, 0..) |c, i| {
                    if (i > 0) buf = buf ++ ", ";
                    // Use sql_name so `__schema.columns` renames work.
                    buf = buf ++ c.sql_name;
                }
            }
            return buf;
        }

        fn selectClause() []const u8 {
            return "SELECT " ++ comptime columnList() ++ " FROM " ++ table_def.table;
        }

        fn buildSelect(arena: std.mem.Allocator, tail: []const u8) ![]const u8 {
            const head = comptime selectClause();
            return std.fmt.allocPrint(arena, "{s}{s}", .{ head, tail });
        }

        fn fetchAll(database: db_mod.Db, arena: std.mem.Allocator, sql: []const u8, args: anytype) ![]T {
            var stmt = try database.prepare(sql);
            defer stmt.deinit();
            try stmt.bindAll(args);
            var out: std.ArrayList(T) = .empty;
            while ((try stmt.step()) == .row) {
                const row = try readRowDupe(arena, stmt);
                try out.append(arena, row);
            }
            return out.toOwnedSlice(arena);
        }

        fn fetchAllStruct(database: db_mod.Db, arena: std.mem.Allocator, sql: []const u8, conds: anytype) ![]T {
            var stmt = try database.prepare(sql);
            defer stmt.deinit();
            inline for (@typeInfo(@TypeOf(conds)).@"struct".fields, 0..) |f, i| {
                const v = @field(conds, f.name);
                try stmt.bind(i + 1, db_mod.Value.fromAny(v));
            }
            var out: std.ArrayList(T) = .empty;
            while ((try stmt.step()) == .row) {
                const row = try readRowDupe(arena, stmt);
                try out.append(arena, row);
            }
            return out.toOwnedSlice(arena);
        }

        /// Read a row into T, duping all []const u8 fields into `arena`.
        fn readRowDupe(arena: std.mem.Allocator, stmt: db_mod.Stmt) !T {
            var out: T = undefined;
            const info = @typeInfo(T).@"struct";
            inline for (info.fields, 0..) |f, i| {
                const FT = f.type;
                const fi = @typeInfo(FT);
                // Enum fields with a `__schema.enums.<field>` mapping are stored
                // as TEXT; we read the raw string and look it up in the map.
                const enum_mapping_present = comptime schema_mod.enumStringsLookup(T, f.name) != null;
                switch (fi) {
                    .optional => |o| {
                        const ChildI = @typeInfo(o.child);
                        switch (ChildI) {
                            .int => @field(out, f.name) = @intCast(try stmt.columnInt(i)),
                            .float => @field(out, f.name) = @floatCast(try stmt.columnFloat(i)),
                            .bool => @field(out, f.name) = (try stmt.columnInt(i)) != 0,
                            .@"enum" => {
                                if (!enum_mapping_present) {
                                    @field(out, f.name) = @enumFromInt(try stmt.columnInt(i));
                                } else {
                                    const raw = try stmt.columnText(i);
                                    if (raw.len == 0) {
                                        @field(out, f.name) = null;
                                    } else {
                                        @field(out, f.name) = try schema_mod.enumFromText(T, f.name, o.child, raw);
                                    }
                                }
                            },
                            .pointer => |p| {
                                if (p.size == .slice and p.child == u8) {
                                    const raw = try stmt.columnText(i);
                                    @field(out, f.name) = try arena.dupe(u8, raw);
                                } else @compileError("readRowDupe: unsupported optional pointer for " ++ f.name);
                            },
                            else => @compileError("readRowDupe: unsupported optional inner " ++ @typeName(o.child)),
                        }
                    },
                    .int => @field(out, f.name) = @intCast(try stmt.columnInt(i)),
                    .float => @field(out, f.name) = @floatCast(try stmt.columnFloat(i)),
                    .bool => @field(out, f.name) = (try stmt.columnInt(i)) != 0,
                    .@"enum" => {
                        if (!enum_mapping_present) {
                            @field(out, f.name) = @enumFromInt(try stmt.columnInt(i));
                        } else {
                            const raw = try stmt.columnText(i);
                            @field(out, f.name) = try schema_mod.enumFromText(T, f.name, FT, raw);
                        }
                    },
                    .pointer => |p| {
                        if (p.size == .slice and p.child == u8) {
                            const raw = try stmt.columnText(i);
                            @field(out, f.name) = try arena.dupe(u8, raw);
                        } else @compileError("readRowDupe: unsupported pointer for " ++ f.name);
                    },
                    else => @compileError("readRowDupe: unsupported field type " ++ @typeName(FT)),
                }
            }
            return out;
        }

        /// Convert `value.<field>` into a Value, respecting enum→TEXT
        /// mappings declared in `__schema.enums`.
        fn fieldValue(comptime field_name: []const u8, value: T) db_mod.Value {
            const FT = @TypeOf(@field(value, field_name));
            const fi = @typeInfo(FT);
            const enum_mapping_present = comptime schema_mod.enumStringsLookup(T, field_name) != null;
            switch (fi) {
                .@"enum" => {
                    if (enum_mapping_present) {
                        return .{ .text = schema_mod.enumToText(T, field_name, @field(value, field_name)) };
                    }
                    return db_mod.Value.fromAny(@field(value, field_name));
                },
                .optional => |o| switch (@typeInfo(o.child)) {
                    .@"enum" => {
                        const inner = @field(value, field_name);
                        if (inner == null) return .{ .null_value = {} };
                        if (enum_mapping_present) {
                            return .{ .text = schema_mod.enumToText(T, field_name, inner.?) };
                        }
                        return db_mod.Value.fromAny(inner.?);
                    },
                    else => return db_mod.Value.fromAny(@field(value, field_name)),
                },
                else => return db_mod.Value.fromAny(@field(value, field_name)),
            }
        }

        fn buildInsert(arena: std.mem.Allocator, value: T) ![]const u8 {
            var col_buf: std.ArrayList(u8) = .empty;
            errdefer col_buf.deinit(arena);
            var val_buf: std.ArrayList(u8) = .empty;
            errdefer val_buf.deinit(arena);
            var first = true;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const v = @field(value, f.name);
                // Runtime-check whether to skip this field; can't `continue`
                // because the inline-for body is partially comptime.
                const is_opt = comptime (@typeInfo(@TypeOf(v)) == .optional);
                const skip: bool = if (is_opt) (v == null) else false;
                if (!skip) {
                    if (!first) {
                        try col_buf.appendSlice(arena, ", ");
                        try val_buf.appendSlice(arena, ", ");
                    }
                    first = false;
                    try col_buf.appendSlice(arena, comptime fieldSqlName(f.name));
                    try val_buf.append(arena, '?');
                }
            }
            // Explicit RETURNING column list (declared order) — NOT `*`.
            // `RETURNING *` yields columns in physical storage order, which an
            // ALTER-added column breaks; readRowDupe reads positionally by
            // struct field, so the list must follow declaration order.
            return std.fmt.allocPrint(arena, "INSERT INTO {s} ({s}) VALUES ({s}) RETURNING {s}", .{
                table_def.table,
                col_buf.items,
                val_buf.items,
                comptime columnList(),
            });
        }

        fn bindInsertArgs(stmt: *db_mod.Stmt, value: T) !void {
            // `idx` has to be a runtime var, because the number of *bound*
            // params depends on the runtime value of the optional fields.
            var idx: usize = 1;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const v = @field(value, f.name);
                const is_opt = comptime (@typeInfo(@TypeOf(v)) == .optional);
                const skip: bool = if (is_opt) (v == null) else false;
                if (!skip) {
                    try stmt.bind(idx, fieldValue(f.name, value));
                    idx += 1;
                }
            }
        }

        fn buildUpdate(arena: std.mem.Allocator) ![]const u8 {
            var set_buf: std.ArrayList(u8) = .empty;
            errdefer set_buf.deinit(arena);
            var first = true;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (comptime std.mem.eql(u8, f.name, table_def.primary_key)) continue;
                if (!first) try set_buf.appendSlice(arena, ", ");
                first = false;
                try set_buf.appendSlice(arena, comptime fieldSqlName(f.name));
                try set_buf.appendSlice(arena, " = ?");
            }
            return std.fmt.allocPrint(arena, "UPDATE {s} SET {s} WHERE {s} = ?", .{
                table_def.table,
                set_buf.items,
                pk_sql_name,
            });
        }

        fn bindUpdateArgs(stmt: *db_mod.Stmt, value: T, pk_val: i64) !void {
            var idx: usize = 1;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (comptime std.mem.eql(u8, f.name, table_def.primary_key)) continue;
                try stmt.bind(idx, fieldValue(f.name, value));
                idx += 1;
            }
            try stmt.bind(idx, .{ .int = pk_val });
        }

        fn findPkField() []const u8 {
            return table_def.primary_key;
        }

        /// SQL name for the primary key column (respects `__schema.columns`).
        /// Available as a compile-time constant so callers can splice it into
        /// string literals with `++`.
        const pk_sql_name: []const u8 = blk: {
            for (table_def.columns) |c| {
                if (std.mem.eql(u8, c.name, table_def.primary_key)) break :blk c.sql_name;
            }
            break :blk table_def.primary_key;
        };

        /// Translate a Zig-side field name to its SQL column name.
        fn fieldSqlName(comptime field_name: []const u8) []const u8 {
            comptime {
                for (table_def.columns) |c| {
                    if (std.mem.eql(u8, c.name, field_name)) return c.sql_name;
                }
                return field_name;
            }
        }
    };
}

/// Convenience: `am.model.repo(User)` is `Repo(User)`.
pub fn repo(comptime T: type) type {
    return Repo(T);
}

// === Tests ===

const testing = std.testing;

const Sqlite = if (@import("builtin").cpu.arch == .wasm32) struct {} else @import("../db/sqlite.zig");

const TestUser = struct {
    id: ?i64 = null,
    email: []const u8,
    name: []const u8,
    age: ?i32 = null,
    created_at: ?i64 = null,

    pub const __schema = .{
        .table = "test_users",
        .primary_key = "id",
    };
};

const RenamedRow = struct {
    id: ?i64 = null,
    userId: i64,
    fullName: []const u8,

    pub const __schema = .{
        .table = "renamed_rows",
        .primary_key = "id",
        .columns = .{
            .userId = "user_id",
            .fullName = "full_name",
        },
    };
};

test "Repo.queryRaw: arbitrary SQL maps back to T" {
    if (@import("builtin").cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();
    const ddl = @import("ddl.zig");
    try database.exec(try ddl.createTable(arena, comptime schema_mod.tableDef(TestUser), .{}));

    const Users = Repo(TestUser);
    _ = try Users.create(database, arena, .{ .email = "a@x", .name = "alice", .age = 30 });
    _ = try Users.create(database, arena, .{ .email = "b@x", .name = "bob", .age = 25 });

    // Custom query: WHERE age > ? LIMIT 1
    const rows = try Users.queryRaw(database, arena,
        "SELECT id, email, name, age, created_at FROM test_users WHERE age > ? ORDER BY age DESC LIMIT 1",
        .{27},
    );
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("alice", rows[0].name);
    try std.testing.expectEqual(@as(?i32, 30), rows[0].age);
}

const TaskStatus = enum { pending, active, done };

const TaskRow = struct {
    id: ?i64 = null,
    title: []const u8,
    status: TaskStatus = .pending,

    pub const __schema = .{
        .table = "task_rows",
        .primary_key = "id",
        .enums = .{
            .status = .{
                .pending = "pending",
                .active = "active",
                .done = "done",
            },
        },
    };
};

test "Repo: enum ↔ TEXT mapping round-trip" {
    if (@import("builtin").cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    const ddl = @import("ddl.zig");
    const td = comptime schema_mod.tableDef(TaskRow);
    const sql = try ddl.createTable(arena, td, .{});
    try database.exec(sql);

    // The status column must be TEXT in DDL (because __schema.enums.status exists).
    try std.testing.expect(std.mem.indexOf(u8, sql, "status TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "status INTEGER") == null);

    const Rows = Repo(TaskRow);

    // Create with .active → stored as "active"
    const created = try Rows.create(database, arena, .{ .title = "ship it", .status = .active });
    try std.testing.expectEqual(TaskStatus.active, created.status);

    // Verify the on-disk representation is the string, not the int.
    var stmt = try database.prepare("SELECT status FROM task_rows WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindAll(.{created.id.?});
    _ = try stmt.step();
    const raw = try stmt.columnText(0);
    try std.testing.expectEqualStrings("active", raw);

    // Save() should round-trip a different variant too.
    var mut = created;
    mut.status = .done;
    try Rows.save(database, arena, &mut);
    const reloaded = (try Rows.find(database, arena, mut.id.?)).?;
    try std.testing.expectEqual(TaskStatus.done, reloaded.status);
}

test "Repo: __schema.columns renames in SELECT/INSERT/UPDATE/DELETE" {
    if (@import("builtin").cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    const ddl = @import("ddl.zig");
    const td = comptime schema_mod.tableDef(RenamedRow);
    const sql = try ddl.createTable(arena, td, .{});
    try database.exec(sql);

    // Verify the DDL used snake_case column names.
    try std.testing.expect(std.mem.indexOf(u8, sql, "user_id INTEGER") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "full_name TEXT") != null);
    // And that the field-case names are *not* present (we'd accidentally use
    // the Zig identifier otherwise).
    try std.testing.expect(std.mem.indexOf(u8, sql, "userId") == null);

    const Rows = Repo(RenamedRow);
    const created = try Rows.create(database, arena, .{ .userId = 42, .fullName = "alice" });
    try std.testing.expect(created.id.? > 0);
    try std.testing.expectEqual(@as(i64, 42), created.userId);
    try std.testing.expectEqualStrings("alice", created.fullName);

    // WHERE uses the Zig field name and we translate it to user_id under the
    // hood — passing `.userId = 42` would fail at the SQL level otherwise.
    const found = try Rows.where(database, arena, .{ .userId = 42 });
    try std.testing.expectEqual(@as(usize, 1), found.len);
}

test "Repo: create / find / where / save / delete on in-memory SQLite" {
    if (@import("builtin").cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    // Bootstrap schema.
    const ddl = @import("ddl.zig");
    const td = comptime schema_mod.tableDef(TestUser);
    const create_sql = try ddl.createTable(arena, td, .{});
    try database.exec(create_sql);

    const Users = Repo(TestUser);

    // CREATE
    const created = try Users.create(database, arena, .{
        .email = "a@ex.com",
        .name = "alice",
        .age = 30,
    });
    try testing.expect(created.id.? > 0);
    try testing.expectEqualStrings("alice", created.name);

    // FIND
    const found = (try Users.find(database, arena, created.id.?)) orelse return error.NotFound;
    try testing.expectEqualStrings("a@ex.com", found.email);
    try testing.expectEqual(@as(?i32, 30), found.age);

    // CREATE 2nd
    _ = try Users.create(database, arena, .{ .email = "b@ex.com", .name = "bob", .age = 25 });

    // WHERE name = "bob"
    const bobs = try Users.where(database, arena, .{ .name = "bob" });
    try testing.expectEqual(@as(usize, 1), bobs.len);
    try testing.expectEqualStrings("b@ex.com", bobs[0].email);

    // SAVE (update)
    var mut = found;
    mut.name = "alice2";
    try Users.save(database, arena, &mut);
    const reloaded = (try Users.find(database, arena, mut.id.?)).?;
    try testing.expectEqualStrings("alice2", reloaded.name);

    // DELETE
    try Users.delete(database, mut.id.?);
    const gone = try Users.find(database, arena, mut.id.?);
    try testing.expect(gone == null);
}
