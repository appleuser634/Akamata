// Auto-diff migrations.
//
// Workflow:
//   1. Collect TableDef[] from the user's models.
//   2. For each table:
//      - If the table doesn't exist in the DB → schedule CREATE TABLE.
//      - If it exists → read its columns via `PRAGMA table_info(<table>)`
//        and `sqlite_master` for indexes, diff against the TableDef.
//        - Columns in model but not in DB → ADD COLUMN.
//        - Columns in DB but not in model → flagged (we don't auto-drop;
//          the operator decides whether to dropColumn manually or migrate
//          the data away).
//        - Indexes in model but not in DB → CREATE INDEX.
//        - Indexes in DB but not in model → flagged (same policy).
//   3. Optionally apply the plan (after dry-run / Y prompt).
//
// Works against any backend the framework supports — SQLite (native), D1
// (Workers), Turso (libsql). `PRAGMA table_info` is a SELECT-shaped query
// in all three so it goes through the normal Db vtable.

const std = @import("std");
const db_mod = @import("../db/db.zig");
const schema_mod = @import("schema.zig");
const ddl_mod = @import("ddl.zig");

pub const PlanAction = union(enum) {
    create_table: schema_mod.TableDef,
    add_column: struct { table: []const u8, col: schema_mod.Column },
    create_index: struct { table: []const u8, index: schema_mod.Index },
    /// Informational only — we don't drop without explicit confirmation.
    extra_column: struct { table: []const u8, name: []const u8 },
    extra_index: struct { table: []const u8, name: []const u8 },
};

pub const Plan = struct {
    actions: []PlanAction,

    pub fn isEmpty(self: Plan) bool {
        for (self.actions) |a| {
            switch (a) {
                .create_table, .add_column, .create_index => return false,
                .extra_column, .extra_index => {}, // informational
            }
        }
        return true;
    }

    pub fn dump(self: Plan, writer: anytype) !void {
        if (self.actions.len == 0) {
            try writer.writeAll("no schema changes\n");
            return;
        }
        for (self.actions) |a| {
            switch (a) {
                .create_table => |td| try writer.print("CREATE TABLE {s} (with {d} columns, {d} indexes)\n", .{ td.table, td.columns.len, td.indexes.len }),
                .add_column => |x| try writer.print("ALTER TABLE {s} ADD COLUMN {s}\n", .{ x.table, x.col.sql_name }),
                .create_index => |x| try writer.print("CREATE INDEX {s} ON {s} ({d} columns)\n", .{ x.index.name, x.table, x.index.columns.len }),
                .extra_column => |x| try writer.print("[WARN] DB has extra column {s}.{s} (no auto-drop)\n", .{ x.table, x.name }),
                .extra_index => |x| try writer.print("[WARN] DB has extra index {s} on {s} (no auto-drop)\n", .{ x.name, x.table }),
            }
        }
    }
};

/// Build a `Plan` from comparing `models` (TableDef[]) against the live DB.
pub fn diff(
    arena: std.mem.Allocator,
    database: db_mod.Db,
    models: []const schema_mod.TableDef,
) !Plan {
    var actions: std.ArrayList(PlanAction) = .empty;
    for (models) |td| {
        if (try tableExists(arena, database, td.table)) {
            try diffTable(arena, database, td, &actions);
        } else {
            try actions.append(arena, .{ .create_table = td });
        }
    }
    return .{ .actions = try actions.toOwnedSlice(arena) };
}

/// Apply the actions in the plan. CREATE TABLE / CREATE INDEX / ADD COLUMN
/// each become a single `db.exec` call. `extra_*` warnings are skipped.
pub fn apply(arena: std.mem.Allocator, database: db_mod.Db, plan: Plan) !void {
    for (plan.actions) |a| {
        switch (a) {
            .create_table => |td| {
                const sql = try ddl_mod.createTable(arena, td, .{});
                try database.exec(sql);
                const ix_stmts = try ddl_mod.createIndexes(arena, td, .{});
                for (ix_stmts) |s| try database.exec(s);
            },
            .add_column => |x| {
                // ALTER TABLE syntax keeps the column-def grammar of CREATE TABLE.
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(arena);
                try buf.appendSlice(arena, "ALTER TABLE ");
                try buf.appendSlice(arena, x.table);
                try buf.appendSlice(arena, " ADD COLUMN ");
                try appendColumnDef(&buf, arena, x.col);
                try database.exec(buf.items);
            },
            .create_index => |x| {
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(arena);
                try buf.appendSlice(arena, "CREATE ");
                if (x.index.unique) try buf.appendSlice(arena, "UNIQUE ");
                try buf.appendSlice(arena, "INDEX IF NOT EXISTS ");
                try buf.appendSlice(arena, x.index.name);
                try buf.appendSlice(arena, " ON ");
                try buf.appendSlice(arena, x.table);
                try buf.appendSlice(arena, " (");
                for (x.index.columns, 0..) |c, i| {
                    if (i > 0) try buf.appendSlice(arena, ", ");
                    try buf.appendSlice(arena, c);
                }
                try buf.append(arena, ')');
                try database.exec(buf.items);
            },
            .extra_column, .extra_index => {},
        }
    }
}

fn appendColumnDef(buf: *std.ArrayList(u8), arena: std.mem.Allocator, col: schema_mod.Column) !void {
    try buf.appendSlice(arena, col.sql_name);
    try buf.append(arena, ' ');
    const sql_name = switch (col.sql_type) {
        .integer => "INTEGER",
        .real => "REAL",
        .text => "TEXT",
        .blob => "BLOB",
    };
    try buf.appendSlice(arena, sql_name);
    if (!col.nullable and !col.primary_key) try buf.appendSlice(arena, " NOT NULL");
}

// === DB introspection ===

fn tableExists(arena: std.mem.Allocator, database: db_mod.Db, name: []const u8) !bool {
    _ = arena;
    var stmt = try database.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?");
    defer stmt.deinit();
    try stmt.bindAll(.{name});
    return (try stmt.step()) == .row;
}

const DbColumn = struct { name: []const u8, sql_type: []const u8, notnull: bool, pk: bool };

fn readColumns(arena: std.mem.Allocator, database: db_mod.Db, table: []const u8) ![]DbColumn {
    // PRAGMA cannot be parameterised — splice the (already validated) table
    // name. The model layer never produces a table name with quotes/spaces.
    const sql = try std.fmt.allocPrint(arena, "PRAGMA table_info({s})", .{table});
    var stmt = try database.prepare(sql);
    defer stmt.deinit();
    var out: std.ArrayList(DbColumn) = .empty;
    while ((try stmt.step()) == .row) {
        // cid(0), name(1), type(2), notnull(3), dflt_value(4), pk(5)
        const name_raw = try stmt.columnText(1);
        const type_raw = try stmt.columnText(2);
        const notnull = (try stmt.columnInt(3)) != 0;
        const pk = (try stmt.columnInt(5)) != 0;
        try out.append(arena, .{
            .name = try arena.dupe(u8, name_raw),
            .sql_type = try arena.dupe(u8, type_raw),
            .notnull = notnull,
            .pk = pk,
        });
    }
    return out.toOwnedSlice(arena);
}

fn readIndexes(arena: std.mem.Allocator, database: db_mod.Db, table: []const u8) ![][]const u8 {
    var stmt = try database.prepare(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name = ? AND name NOT LIKE 'sqlite_%'",
    );
    defer stmt.deinit();
    try stmt.bindAll(.{table});
    var out: std.ArrayList([]const u8) = .empty;
    while ((try stmt.step()) == .row) {
        const raw = try stmt.columnText(0);
        try out.append(arena, try arena.dupe(u8, raw));
    }
    return out.toOwnedSlice(arena);
}

fn diffTable(
    arena: std.mem.Allocator,
    database: db_mod.Db,
    td: schema_mod.TableDef,
    actions: *std.ArrayList(PlanAction),
) !void {
    const db_cols = try readColumns(arena, database, td.table);
    const db_ixs = try readIndexes(arena, database, td.table);

    // Columns in model but not in DB → ADD COLUMN. Compare PRAGMA's column
    // name against the model's SQL-side name (so `userId` field mapped to
    // `user_id` column matches the row PRAGMA returns).
    for (td.columns) |mc| {
        var present = false;
        for (db_cols) |dc| if (std.mem.eql(u8, dc.name, mc.sql_name)) {
            present = true;
        };
        if (!present) {
            try actions.append(arena, .{ .add_column = .{ .table = td.table, .col = mc } });
        }
    }
    // Columns in DB but not in model → warn
    for (db_cols) |dc| {
        var present = false;
        for (td.columns) |mc| if (std.mem.eql(u8, dc.name, mc.sql_name)) {
            present = true;
        };
        if (!present) {
            try actions.append(arena, .{ .extra_column = .{ .table = td.table, .name = dc.name } });
        }
    }
    // Indexes
    for (td.indexes) |mi| {
        var present = false;
        for (db_ixs) |di| if (std.mem.eql(u8, di, mi.name)) {
            present = true;
        };
        if (!present) {
            try actions.append(arena, .{ .create_index = .{ .table = td.table, .index = mi } });
        }
    }
    for (db_ixs) |di| {
        var present = false;
        for (td.indexes) |mi| if (std.mem.eql(u8, di, mi.name)) {
            present = true;
        };
        if (!present) {
            try actions.append(arena, .{ .extra_index = .{ .table = td.table, .name = di } });
        }
    }
}

// === Deferred (first-request) migrate, for Workers ===
//
// On Cloudflare Workers we can't call `diff/apply` from `akamata_init` —
// that runs inside `WebAssembly.instantiate()` where JSPI Suspending is not
// available yet. The fix is to defer migrate until the *first* HTTP request:
// the wasm stack is then inside a `WebAssembly.promising`-wrapped call and
// D1 imports can suspend freely.
//
// `Once` is a backend-agnostic, allocator-free helper that wraps the
// diff+apply pair behind a one-shot atomic guard.

pub const Once = struct {
    done: std.atomic.Value(u8) = .init(0),

    /// Idempotent: only the first caller actually runs the migration.
    /// Subsequent callers (including parallel ones) short-circuit.
    pub fn run(
        self: *Once,
        arena: std.mem.Allocator,
        database: db_mod.Db,
        models: []const schema_mod.TableDef,
    ) !void {
        // Fast path: already done.
        if (self.done.load(.acquire) == 2) return;
        // Use cmpxchgStrong (no spurious failures) to claim the work.
        const prev = self.done.cmpxchgStrong(0, 1, .acquire, .monotonic);
        if (prev == null) {
            errdefer self.done.store(0, .release);
            const plan = try diff(arena, database, models);
            try apply(arena, database, plan);
            self.done.store(2, .release);
            return;
        }
        // Someone else won the race. Spin briefly until they publish 2.
        // On Workers (single-threaded JS), this branch is unreachable.
        while (true) {
            const state = self.done.load(.acquire);
            if (state == 2) return;
            if (state == 0) return self.run(arena, database, models);
            std.atomic.spinLoopHint();
        }
    }
};

// === Versioned, file-based migrations ===
//
// Each migration is a SQL file named `<version>_<description>.sql` (the
// version is normally a timestamp like `20260522231500`). The runner reads
// the directory in name order, looks up `schema_migrations.version`, and
// applies any files whose version is not yet recorded.
//
// File contents are run through `Db.execAll`. SQLite delegates scripts to its
// own parser; portable backends use a quote/comment-aware splitter.
//
// SQLite and Turso apply each file and its version record in one transaction
// and roll back on failure. D1 does not expose equivalent transaction control
// through this bridge, so D1 migrations should remain small and idempotent.

pub const Migration = struct {
    /// Version identifier (the timestamp prefix of the filename, e.g.
    /// "20260522231500"). Treated as opaque text — sorted lexicographically.
    version: []const u8,
    /// File basename (for diagnostics).
    name: []const u8,
    /// SQL script body, already loaded into memory.
    sql: []const u8,
};

pub const Migrator = struct {
    arena: std.mem.Allocator,
    db: db_mod.Db,

    /// Create the `schema_migrations` table if missing.
    pub fn ensureTable(self: Migrator) !void {
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\  version TEXT PRIMARY KEY,
            \\  applied_at INTEGER NOT NULL
            \\) STRICT
        );
    }

    /// Returns a sorted list of versions already applied. Caller owns memory
    /// (allocated in `arena`).
    pub fn appliedVersions(self: Migrator) ![][]const u8 {
        try self.ensureTable();
        var stmt = try self.db.prepare("SELECT version FROM schema_migrations ORDER BY version");
        defer stmt.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        while ((try stmt.step()) == .row) {
            const raw = try stmt.columnText(0);
            try out.append(self.arena, try self.arena.dupe(u8, raw));
        }
        return out.toOwnedSlice(self.arena);
    }

    /// Apply every migration in `to_apply`, in order. Each one records its
    /// version into `schema_migrations` immediately after success.
    pub fn applyAll(self: Migrator, to_apply: []const Migration) !void {
        try self.ensureTable();
        for (to_apply) |m| {
            try self.applyOne(m);
        }
    }

    fn applyOne(self: Migrator, m: Migration) !void {
        const transactional = self.db.backend != .d1;
        if (transactional) try self.db.exec("BEGIN IMMEDIATE");
        errdefer if (transactional) self.db.exec("ROLLBACK") catch {};
        // Reversible files keep rollback statements after this marker. Never
        // execute that section while migrating forward. Legacy files without
        // a marker continue to execute in full.
        const down_marker = "-- migrate:down";
        const up_sql = if (std.mem.indexOf(u8, m.sql, down_marker)) |at| m.sql[0..at] else m.sql;
        try self.db.execAll(up_sql);
        var record = try self.db.prepare(
            "INSERT INTO schema_migrations(version, applied_at) VALUES(?, unixepoch())",
        );
        defer record.deinit();
        try record.bindAll(.{m.version});
        _ = try record.step();
        if (transactional) try self.db.exec("COMMIT");
    }

    /// Filter `all` down to migrations not yet recorded in
    /// `schema_migrations`. The result preserves input order.
    pub fn pending(self: Migrator, all: []const Migration) ![]const Migration {
        const applied = try self.appliedVersions();
        var out: std.ArrayList(Migration) = .empty;
        for (all) |m| {
            var seen = false;
            for (applied) |v| if (std.mem.eql(u8, v, m.version)) {
                seen = true;
            };
            if (!seen) try out.append(self.arena, m);
        }
        return out.toOwnedSlice(self.arena);
    }

    /// Roll back the most recently applied migration. Reversible migration
    /// files put their down SQL after a `-- migrate:down` marker.
    pub fn rollbackLast(self: Migrator, all: []const Migration) !?Migration {
        const applied = try self.appliedVersions();
        if (applied.len == 0) return null;
        const version = applied[applied.len - 1];
        for (all) |m| {
            if (!std.mem.eql(u8, m.version, version)) continue;
            const marker = "-- migrate:down";
            const at = std.mem.indexOf(u8, m.sql, marker) orelse return error.IrreversibleMigration;
            const down = std.mem.trim(u8, m.sql[at + marker.len ..], " \t\r\n");
            if (down.len == 0) return error.IrreversibleMigration;
            const transactional = self.db.backend != .d1;
            if (transactional) try self.db.exec("BEGIN IMMEDIATE");
            errdefer if (transactional) self.db.exec("ROLLBACK") catch {};
            try self.db.execAll(down);
            var remove = try self.db.prepare("DELETE FROM schema_migrations WHERE version = ?");
            defer remove.deinit();
            try remove.bindAll(.{version});
            _ = try remove.step();
            if (transactional) try self.db.exec("COMMIT");
            return m;
        }
        return error.AppliedMigrationFileMissing;
    }
};

/// Load every `*.sql` file from `dir`, in lexicographic order, parsing the
/// version (the part before the first underscore) out of each filename.
/// Native-only (uses libc readdir + fread).
pub fn loadMigrationsFromDir(arena: std.mem.Allocator, dir_path: []const u8) ![]Migration {
    const dirent_lib = struct {
        const DIR = opaque {};
        const dirent = extern struct {
            d_ino: u64,
            d_seekoff: u64,
            d_reclen: u16,
            d_namlen: u16,
            d_type: u8,
            d_name: [1024]u8,
        };
        extern "c" fn opendir(p: [*:0]const u8) ?*DIR;
        extern "c" fn readdir(d: *DIR) ?*dirent;
        extern "c" fn closedir(d: *DIR) c_int;
    };

    const dir_z = try arena.dupeZ(u8, dir_path);
    defer arena.free(dir_z);
    const d = dirent_lib.opendir(dir_z.ptr) orelse return error.MigrationsDirNotFound;
    defer _ = dirent_lib.closedir(d);

    var names: std.ArrayList([]u8) = .empty;
    while (dirent_lib.readdir(d)) |entry| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.d_name)), 0);
        if (!std.mem.endsWith(u8, name, ".sql")) continue;
        try names.append(arena, try arena.dupe(u8, name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var out: std.ArrayList(Migration) = .empty;
    for (names.items) |name| {
        const underscore = std.mem.indexOfScalar(u8, name, '_') orelse continue;
        const version = name[0..underscore];
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, name });
        const sql = try readFileToArena(arena, path);
        try out.append(arena, .{
            .version = try arena.dupe(u8, version),
            .name = name,
            .sql = sql,
        });
    }
    return out.toOwnedSlice(arena);
}

fn readFileToArena(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    const FILE = opaque {};
    const Lib = struct {
        extern "c" fn fopen(p: [*:0]const u8, m: [*:0]const u8) ?*FILE;
        extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, s: *FILE) usize;
        extern "c" fn fseek(s: *FILE, off: c_long, whence: c_int) c_int;
        extern "c" fn ftell(s: *FILE) c_long;
        extern "c" fn fclose(s: *FILE) c_int;
    };
    const path_z = try arena.dupeZ(u8, path);
    defer arena.free(path_z);
    const f = Lib.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = Lib.fclose(f);
    _ = Lib.fseek(f, 0, 2);
    const sz_s = Lib.ftell(f);
    if (sz_s < 0) return error.FileNotFound;
    const sz: usize = @intCast(sz_s);
    _ = Lib.fseek(f, 0, 0);
    const buf = try arena.alloc(u8, sz);
    const got = Lib.fread(buf.ptr, 1, sz, f);
    return buf[0..got];
}

// === Tests ===

const testing = std.testing;
const builtin = @import("builtin");
const Sqlite = if (builtin.cpu.arch == .wasm32) struct {} else @import("../db/sqlite.zig");

const TestUser = struct {
    id: ?i64 = null,
    email: []const u8,
    name: []const u8,
    age: ?i32 = null,

    pub const __schema = .{
        .table = "test_users_mig",
        .primary_key = "id",
        .indexes = .{
            .{ "email", .unique },
        },
    };
};

const TestUserV2 = struct {
    id: ?i64 = null,
    email: []const u8,
    name: []const u8,
    age: ?i32 = null,
    bio: []const u8 = "",

    pub const __schema = .{
        .table = "test_users_mig",
        .primary_key = "id",
        .indexes = .{
            .{ "email", .unique },
            .{ "name", .index },
        },
    };
};

test "migrate.diff: empty DB → CREATE TABLE planned" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    const td = comptime schema_mod.tableDef(TestUser);
    const plan = try diff(arena, database, &.{td});
    try testing.expectEqual(@as(usize, 1), plan.actions.len);
    try testing.expect(plan.actions[0] == .create_table);
}

test "migrate.apply + diff: re-apply is a no-op" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    const td = comptime schema_mod.tableDef(TestUser);
    var plan = try diff(arena, database, &.{td});
    try apply(arena, database, plan);

    // Second diff: nothing should happen.
    plan = try diff(arena, database, &.{td});
    try testing.expect(plan.isEmpty());
}

test "Migrator: applies versioned files in order and tracks them" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    const all = [_]Migration{
        .{
            .version = "20260101000001",
            .name = "20260101000001_init.sql",
            .sql =
            \\CREATE TABLE accounts (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;
            ,
        },
        .{
            .version = "20260101000002",
            .name = "20260101000002_add_email.sql",
            .sql = "ALTER TABLE accounts ADD COLUMN email TEXT",
        },
    };

    const m: Migrator = .{ .arena = arena, .db = database };
    // First run: 2 pending.
    var p = try m.pending(&all);
    try testing.expectEqual(@as(usize, 2), p.len);
    try m.applyAll(p);

    // Schema check: column count = 2 + email = 3.
    var stmt = try database.prepare("PRAGMA table_info(accounts)");
    defer stmt.deinit();
    var col_count: usize = 0;
    while ((try stmt.step()) == .row) col_count += 1;
    try testing.expectEqual(@as(usize, 3), col_count);

    // Second run: nothing pending.
    p = try m.pending(&all);
    try testing.expectEqual(@as(usize, 0), p.len);

    // appliedVersions in order
    const av = try m.appliedVersions();
    try testing.expectEqual(@as(usize, 2), av.len);
    try testing.expectEqualStrings("20260101000001", av[0]);
    try testing.expectEqualStrings("20260101000002", av[1]);
}

test "Migrator rolls back a failed SQLite migration" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();
    const m: Migrator = .{ .arena = arena, .db = database };
    const broken = [_]Migration{.{
        .version = "quoted'value",
        .name = "broken.sql",
        .sql = "CREATE TABLE must_rollback (id INTEGER); THIS IS NOT SQL;",
    }};
    try testing.expectError(error.ExecFailed, m.applyAll(&broken));
    var stmt = try database.prepare(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='must_rollback'",
    );
    defer stmt.deinit();
    try testing.expectEqual(db_mod.StepResult.done, try stmt.step());
}

test "Migrator executes only up section and can roll it back" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();
    const migration = Migration{
        .version = "20260817000000",
        .name = "20260817000000_widgets.sql",
        .sql =
        \\-- migrate:up
        \\CREATE TABLE widgets (id INTEGER PRIMARY KEY) STRICT;
        \\-- migrate:down
        \\DROP TABLE widgets;
        ,
    };
    const m: Migrator = .{ .arena = arena, .db = database };
    try m.applyAll(&.{migration});
    var exists = try database.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='widgets'");
    try testing.expectEqual(db_mod.StepResult.row, try exists.step());
    exists.deinit();
    const rolled_back = try m.rollbackLast(&.{migration});
    try testing.expect(rolled_back != null);
    const applied = try m.appliedVersions();
    try testing.expectEqual(@as(usize, 0), applied.len);
}

test "migrate: schema evolution (add column + new index)" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    // V1 schema
    const td1 = comptime schema_mod.tableDef(TestUser);
    var plan = try diff(arena, database, &.{td1});
    try apply(arena, database, plan);

    // V2 schema (adds bio column + name index)
    const td2 = comptime schema_mod.tableDef(TestUserV2);
    plan = try diff(arena, database, &.{td2});

    // Expect: add_column(bio) + create_index(name)
    var add_col = false;
    var add_idx = false;
    for (plan.actions) |a| switch (a) {
        .add_column => |x| if (std.mem.eql(u8, x.col.name, "bio")) {
            add_col = true;
        },
        .create_index => |x| if (std.mem.eql(u8, x.index.name, "test_users_mig_name_idx")) {
            add_idx = true;
        },
        else => {},
    };
    try testing.expect(add_col);
    try testing.expect(add_idx);

    try apply(arena, database, plan);

    // Third diff: clean.
    plan = try diff(arena, database, &.{td2});
    try testing.expect(plan.isEmpty());
}
