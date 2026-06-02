// Relations: belongs_to + has_many, defined via `__schema.relations`.
//
// Example:
//
//     const User = struct {
//         id: ?i64 = null,
//         name: []const u8,
//         pub const __schema = .{
//             .table = "users",
//             .relations = .{
//                 .posts = .{ .has_many = .{ .model = Post, .fk = "user_id" } },
//             },
//         };
//     };
//
//     const Post = struct {
//         id: ?i64 = null,
//         user_id: i64,
//         title: []const u8,
//         pub const __schema = .{
//             .table = "posts",
//             .relations = .{
//                 .user = .{ .belongs_to = .{ .model = User, .fk = "user_id" } },
//             },
//         };
//     };
//
// Usage (through `am.model.relations`):
//
//     const user_posts = try am.model.relations.hasMany(User, "posts", db, arena, user_id);
//     const post_user  = try am.model.relations.belongsTo(Post, "user",  db, arena, post);
//
// (We don't generate methods on the struct itself — Zig's decl model makes
// that awkward — so relations live as comptime-resolved helpers that take
// the source model + relation name.)

const std = @import("std");
const db_mod = @import("../db/db.zig");
const schema_mod = @import("schema.zig");
const query_mod = @import("query.zig");

/// `hasMany(Owner, "posts", db, arena, owner_id)` returns `[]Post`.
pub fn hasMany(
    comptime Owner: type,
    comptime relation_name: []const u8,
    database: db_mod.Db,
    arena: std.mem.Allocator,
    owner_id: i64,
) ![]const RelTarget(Owner, relation_name) {
    const Target = RelTarget(Owner, relation_name);
    const rel = comptime resolveHasMany(Owner, relation_name);
    // We can't directly call Repo.where (it takes an anon struct whose field
    // name must be a comptime string), so route through whereOne.
    return whereOne(Target, rel.fk, owner_id, database, arena);
}

/// `belongsTo(Owner, "user", db, arena, owner)` returns `?User`.
pub fn belongsTo(
    comptime Owner: type,
    comptime relation_name: []const u8,
    database: db_mod.Db,
    arena: std.mem.Allocator,
    owner: Owner,
) !?RelTarget(Owner, relation_name) {
    const rel = comptime resolveBelongsTo(Owner, relation_name);
    const Target = RelTarget(Owner, relation_name);
    const fk_value = @field(owner, rel.fk);
    const fk_int: i64 = switch (@typeInfo(@TypeOf(fk_value))) {
        .int, .comptime_int => @intCast(fk_value),
        .optional => |o| blk: {
            _ = o;
            break :blk if (fk_value) |x| @as(i64, @intCast(x)) else return null;
        },
        else => @compileError("belongs_to fk must be an integer"),
    };
    return query_mod.Repo(Target).find(database, arena, fk_int);
}

/// Resolve the target model type for a relation (comptime).
pub fn RelTarget(comptime Owner: type, comptime relation_name: []const u8) type {
    const rels = Owner.__schema.relations;
    const spec = @field(rels, relation_name);
    if (@hasField(@TypeOf(spec), "has_many")) return spec.has_many.model;
    if (@hasField(@TypeOf(spec), "belongs_to")) return spec.belongs_to.model;
    @compileError("relation '" ++ relation_name ++ "' on " ++ @typeName(Owner) ++ " has neither has_many nor belongs_to");
}

const HasManyInfo = struct { model: type, fk: []const u8 };
const BelongsToInfo = struct { model: type, fk: []const u8 };

fn resolveHasMany(comptime Owner: type, comptime relation_name: []const u8) HasManyInfo {
    const spec = @field(Owner.__schema.relations, relation_name);
    if (!@hasField(@TypeOf(spec), "has_many")) {
        @compileError(relation_name ++ " is not a has_many relation on " ++ @typeName(Owner));
    }
    return .{ .model = spec.has_many.model, .fk = spec.has_many.fk };
}

fn resolveBelongsTo(comptime Owner: type, comptime relation_name: []const u8) BelongsToInfo {
    const spec = @field(Owner.__schema.relations, relation_name);
    if (!@hasField(@TypeOf(spec), "belongs_to")) {
        @compileError(relation_name ++ " is not a belongs_to relation on " ++ @typeName(Owner));
    }
    return .{ .model = spec.belongs_to.model, .fk = spec.belongs_to.fk };
}

/// `WHERE {col} = ?` query — single-column equality. Used internally to
/// avoid the anonymous-struct dance of `Repo.where`.
fn whereOne(
    comptime T: type,
    col: []const u8,
    value: i64,
    database: db_mod.Db,
    arena: std.mem.Allocator,
) ![]T {
    const td = comptime schema_mod.tableDef(T);
    var sql_buf: std.ArrayList(u8) = .empty;
    errdefer sql_buf.deinit(arena);
    try sql_buf.appendSlice(arena, "SELECT ");
    inline for (td.columns, 0..) |c, i| {
        if (i > 0) try sql_buf.appendSlice(arena, ", ");
        try sql_buf.appendSlice(arena, c.sql_name);
    }
    try sql_buf.appendSlice(arena, " FROM ");
    try sql_buf.appendSlice(arena, td.table);
    try sql_buf.appendSlice(arena, " WHERE ");
    // Translate the model-side fk field name to its SQL name.
    var fk_sql: []const u8 = col;
    for (td.columns) |c| {
        if (std.mem.eql(u8, c.name, col)) {
            fk_sql = c.sql_name;
            break;
        }
    }
    try sql_buf.appendSlice(arena, fk_sql);
    try sql_buf.appendSlice(arena, " = ? ORDER BY ");
    // PK sql name
    var pk_sql: []const u8 = td.primary_key;
    for (td.columns) |c| {
        if (std.mem.eql(u8, c.name, td.primary_key)) {
            pk_sql = c.sql_name;
            break;
        }
    }
    try sql_buf.appendSlice(arena, pk_sql);
    try sql_buf.appendSlice(arena, " DESC");

    var stmt = try database.prepare(sql_buf.items);
    defer stmt.deinit();
    try stmt.bindAll(.{value});
    var out: std.ArrayList(T) = .empty;
    while ((try stmt.step()) == .row) {
        const row = try readRowDupe(T, arena, stmt);
        try out.append(arena, row);
    }
    return out.toOwnedSlice(arena);
}

/// Mirrors query.zig's readRowDupe — duped string fields, optional support.
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
                    } else @compileError("relations.readRowDupe: unsupported ?ptr type for " ++ f.name);
                },
                else => @compileError("relations.readRowDupe: unsupported ? inner " ++ @typeName(o.child)),
            },
            .int => @field(out, f.name) = @intCast(try stmt.columnInt(i)),
            .float => @field(out, f.name) = @floatCast(try stmt.columnFloat(i)),
            .bool => @field(out, f.name) = (try stmt.columnInt(i)) != 0,
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    @field(out, f.name) = try arena.dupe(u8, try stmt.columnText(i));
                } else @compileError("relations.readRowDupe: unsupported pointer for " ++ f.name);
            },
            else => @compileError("relations.readRowDupe: unsupported field " ++ @typeName(FT)),
        }
    }
    return out;
}

// === Tests ===

const testing = std.testing;
const builtin = @import("builtin");
const ddl_mod = @import("ddl.zig");
const Sqlite = if (builtin.cpu.arch == .wasm32) struct {} else @import("../db/sqlite.zig");

const RelPost = struct {
    id: ?i64 = null,
    user_id: i64,
    title: []const u8,

    pub const __schema = .{
        .table = "rel_posts",
        .primary_key = "id",
        .relations = .{
            .user = .{ .belongs_to = .{ .model = RelUser, .fk = "user_id" } },
        },
    };
};

const RelUser = struct {
    id: ?i64 = null,
    name: []const u8,

    pub const __schema = .{
        .table = "rel_users",
        .primary_key = "id",
        .relations = .{
            .posts = .{ .has_many = .{ .model = RelPost, .fk = "user_id" } },
        },
    };
};

test "relations: has_many + belongs_to on SQLite" {
    if (builtin.cpu.arch == .wasm32) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try Sqlite.open(testing.allocator, ":memory:");
    defer database.close();

    // Schema setup
    const u_td = comptime schema_mod.tableDef(RelUser);
    const p_td = comptime schema_mod.tableDef(RelPost);
    try database.exec(try ddl_mod.createTable(arena, u_td, .{}));
    try database.exec(try ddl_mod.createTable(arena, p_td, .{}));

    // Seed data
    const Users = query_mod.Repo(RelUser);
    const Posts = query_mod.Repo(RelPost);
    const alice = try Users.create(database, arena, .{ .name = "alice" });
    _ = try Posts.create(database, arena, .{ .user_id = alice.id.?, .title = "first" });
    _ = try Posts.create(database, arena, .{ .user_id = alice.id.?, .title = "second" });

    // has_many
    const alices_posts = try hasMany(RelUser, "posts", database, arena, alice.id.?);
    try testing.expectEqual(@as(usize, 2), alices_posts.len);

    // belongs_to
    const owner = (try belongsTo(RelPost, "user", database, arena, alices_posts[0])) orelse return error.MissingOwner;
    try testing.expectEqualStrings("alice", owner.name);
}
