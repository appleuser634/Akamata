// Eager loading helpers — defeat N+1 queries with a single batch fetch.
//
// Usage (has_many):
//
//     const Users = am.model.repo(User);
//     const owners = try Users.all(db, arena);
//     const loaded = try am.model.preload.hasMany(User, "posts", owners, db, arena);
//     for (loaded) |row| {
//         // row.parent: User
//         // row.related: []Post  (all posts whose user_id == row.parent.id)
//     }
//
// One `SELECT ... WHERE user_id IN (?, ?, ?, ...)` covers every parent.
// Returned slices live in `arena`.
//
// belongsTo eager loading is symmetric — given children, fetch their parents
// in one query — but we ship hasMany first since it's the more common N+1
// case (rendering a list page with related rows).

const std = @import("std");
const db_mod = @import("../db/db.zig");
const schema_mod = @import("schema.zig");
const relations_mod = @import("relations.zig");

/// Wrapper returned by `hasMany`. Keeps the parent unchanged and adds the
/// preloaded children as a sibling field. Generated per-Owner+relation_name
/// at comptime so the field layout stays static.
pub fn Loaded(comptime Owner: type, comptime relation_name: []const u8) type {
    return struct {
        parent: Owner,
        related: []const relations_mod.RelTarget(Owner, relation_name),
    };
}

/// Fetch every child row for `parents` in one `WHERE fk IN (...)` query.
/// Returns `[]Loaded(Owner, relation_name)` with each parent paired against
/// its matching children.
pub fn hasMany(
    comptime Owner: type,
    comptime relation_name: []const u8,
    parents: []const Owner,
    database: db_mod.Db,
    arena: std.mem.Allocator,
) ![]Loaded(Owner, relation_name) {
    const Target = relations_mod.RelTarget(Owner, relation_name);
    const td = comptime schema_mod.tableDef(Target);
    // Resolve the FK and the parent PK at comptime.
    const fk = comptime resolveHasManyFk(Owner, relation_name);
    const pk = comptime schema_mod.tableDef(Owner).primary_key;

    // 1) Collect parent IDs into a comma-joined ?,?,? placeholder + args.
    var id_vals: std.ArrayList(i64) = .empty;
    errdefer id_vals.deinit(arena);
    for (parents) |p| {
        const v = @field(p, pk);
        const id: ?i64 = switch (@typeInfo(@TypeOf(v))) {
            .optional => |o| blk: {
                _ = o;
                break :blk if (v) |x| @as(i64, @intCast(x)) else null;
            },
            else => @as(i64, @intCast(v)),
        };
        if (id) |x| try id_vals.append(arena, x);
    }
    if (id_vals.items.len == 0) {
        // No parents → an empty Loaded list (or all parents have null pks).
        var out: std.ArrayList(Loaded(Owner, relation_name)) = .empty;
        for (parents) |p| try out.append(arena, .{ .parent = p, .related = &.{} });
        return out.toOwnedSlice(arena);
    }

    // 2) Build SQL.
    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(arena);
    try sql.appendSlice(arena, "SELECT ");
    inline for (td.columns, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(arena, ", ");
        try sql.appendSlice(arena, c.sql_name);
    }
    try sql.appendSlice(arena, " FROM ");
    try sql.appendSlice(arena, td.table);
    try sql.appendSlice(arena, " WHERE ");
    // Resolve fk's SQL-side name.
    var fk_sql: []const u8 = fk;
    inline for (td.columns) |c| {
        if (std.mem.eql(u8, c.name, fk)) {
            fk_sql = c.sql_name;
            break;
        }
    }
    try sql.appendSlice(arena, fk_sql);
    try sql.appendSlice(arena, " IN (");
    for (id_vals.items, 0..) |_, i| {
        if (i > 0) try sql.appendSlice(arena, ", ");
        try sql.append(arena, '?');
    }
    try sql.appendSlice(arena, ")");

    // 3) Run + read.
    var stmt = try database.prepare(sql.items);
    defer stmt.deinit();
    for (id_vals.items, 0..) |v, i| {
        try stmt.bind(i + 1, .{ .int = v });
    }
    var rows: std.ArrayList(Target) = .empty;
    while ((try stmt.step()) == .row) {
        const row = try readRowDupe(Target, arena, stmt);
        try rows.append(arena, row);
    }

    // 4) Bucket rows by fk and pair them with parents (preserving input order).
    var out: std.ArrayList(Loaded(Owner, relation_name)) = .empty;
    for (parents) |p| {
        const v = @field(p, pk);
        const id: ?i64 = switch (@typeInfo(@TypeOf(v))) {
            .optional => |o| blk: {
                _ = o;
                break :blk if (v) |x| @as(i64, @intCast(x)) else null;
            },
            else => @as(i64, @intCast(v)),
        };
        var children: std.ArrayList(Target) = .empty;
        if (id) |pid| {
            for (rows.items) |r| {
                const fk_v = @field(r, fk);
                const fk_int: i64 = @intCast(fk_v);
                if (fk_int == pid) try children.append(arena, r);
            }
        }
        try out.append(arena, .{
            .parent = p,
            .related = try children.toOwnedSlice(arena),
        });
    }
    return out.toOwnedSlice(arena);
}

fn resolveHasManyFk(comptime Owner: type, comptime relation_name: []const u8) []const u8 {
    const spec = @field(Owner.__schema.relations, relation_name);
    if (!@hasField(@TypeOf(spec), "has_many")) {
        @compileError(relation_name ++ " is not a has_many relation on " ++ @typeName(Owner));
    }
    return spec.has_many.fk;
}

/// Mirror of relations.readRowDupe — duped strings, optional support.
fn readRowDupe(comptime T: type, arena: std.mem.Allocator, stmt: db_mod.Stmt) !T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        const FT = f.type;
        switch (@typeInfo(FT)) {
            .optional => |o| switch (@typeInfo(o.child)) {
                .int => @field(out, f.name) = @intCast(try stmt.columnInt(i)),
                .float => @field(out, f.name) = @floatCast(try stmt.columnFloat(i)),
                .bool => @field(out, f.name) = (try stmt.columnInt(i)) != 0,
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) {
                        @field(out, f.name) = try arena.dupe(u8, try stmt.columnText(i));
                    } else @compileError("preload: unsupported ?ptr for " ++ f.name);
                },
                else => @compileError("preload: unsupported ? inner " ++ @typeName(o.child)),
            },
            .int => @field(out, f.name) = @intCast(try stmt.columnInt(i)),
            .float => @field(out, f.name) = @floatCast(try stmt.columnFloat(i)),
            .bool => @field(out, f.name) = (try stmt.columnInt(i)) != 0,
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    @field(out, f.name) = try arena.dupe(u8, try stmt.columnText(i));
                } else @compileError("preload: unsupported pointer for " ++ f.name);
            },
            else => @compileError("preload: unsupported field " ++ @typeName(FT)),
        }
    }
    return out;
}

// === Tests ===

const testing = std.testing;
const builtin = @import("builtin");
const ddl_mod = @import("ddl.zig");
const query_mod = @import("query.zig");
const Sqlite = if (builtin.cpu.arch == .wasm32) struct {} else @import("../db/sqlite.zig");

const PrePost = struct {
    id: ?i64 = null,
    user_id: i64,
    title: []const u8,

    pub const __schema = .{
        .table = "pre_posts",
        .primary_key = "id",
    };
};

const PreUser = struct {
    id: ?i64 = null,
    name: []const u8,

    pub const __schema = .{
        .table = "pre_users",
        .primary_key = "id",
        .relations = .{
            .posts = .{ .has_many = .{ .model = PrePost, .fk = "user_id" } },
        },
    };
};

test "preload.hasMany: one IN-query for N parents" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    try database.exec(try ddl_mod.createTable(arena, comptime schema_mod.tableDef(PreUser), .{}));
    try database.exec(try ddl_mod.createTable(arena, comptime schema_mod.tableDef(PrePost), .{}));

    const Users = query_mod.Repo(PreUser);
    const Posts = query_mod.Repo(PrePost);

    const alice = try Users.create(database, arena, .{ .name = "alice" });
    const bob = try Users.create(database, arena, .{ .name = "bob" });
    _ = try Users.create(database, arena, .{ .name = "carol" }); // no posts
    _ = try Posts.create(database, arena, .{ .user_id = alice.id.?, .title = "a1" });
    _ = try Posts.create(database, arena, .{ .user_id = alice.id.?, .title = "a2" });
    _ = try Posts.create(database, arena, .{ .user_id = bob.id.?, .title = "b1" });

    const all_users = try Users.all(database, arena);
    try testing.expectEqual(@as(usize, 3), all_users.len);

    const loaded = try hasMany(PreUser, "posts", all_users, database, arena);
    try testing.expectEqual(@as(usize, 3), loaded.len);

    // Output order matches input order (newest user first because Users.all sorts DESC).
    // carol has no posts → empty.
    var found_alice = false;
    var found_bob = false;
    var found_carol = false;
    for (loaded) |row| {
        if (std.mem.eql(u8, row.parent.name, "alice")) {
            try testing.expectEqual(@as(usize, 2), row.related.len);
            found_alice = true;
        } else if (std.mem.eql(u8, row.parent.name, "bob")) {
            try testing.expectEqual(@as(usize, 1), row.related.len);
            try testing.expectEqualStrings("b1", row.related[0].title);
            found_bob = true;
        } else if (std.mem.eql(u8, row.parent.name, "carol")) {
            try testing.expectEqual(@as(usize, 0), row.related.len);
            found_carol = true;
        }
    }
    try testing.expect(found_alice);
    try testing.expect(found_bob);
    try testing.expect(found_carol);
}
