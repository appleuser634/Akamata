// Comptime model introspection.
//
// Given a Zig struct that defines an Akamata model:
//
//     pub const User = struct {
//         id: ?i64 = null,
//         email: []const u8,
//         name: []const u8,
//         age: ?i32 = null,
//         created_at: ?i64 = null,
//
//         pub const __schema = .{
//             .table = "users",                 // optional, defaults to lowercased struct name + "s"
//             .primary_key = "id",              // optional, defaults to "id"
//             .indexes = .{
//                 .{ "email", .unique },
//             },
//             // .validates / .relations parsed by sibling modules
//         };
//     };
//
// `tableDef(Model)` walks the struct's fields + the optional `__schema`
// declaration and returns a `TableDef` value containing everything the rest
// of the model layer (DDL, query, migrate) needs at runtime.
//
// All inspection is comptime; the runtime cost is just a constant struct.

const std = @import("std");

pub const SqlType = enum {
    integer, // i8..i64, u8..u32 (u64 rejected — SQLite is signed only)
    real, // f32, f64
    text, // []const u8
    blob, // []const u8 marked as blob via @schema (not yet implemented)
};

pub const Column = struct {
    /// Zig field name (the name used in code).
    name: []const u8,
    /// Column name in SQL. Defaults to `name`; can be overridden through
    /// `__schema.columns = .{ .userId = "user_id" }` to keep Zig identifiers
    /// camelCase and SQL identifiers snake_case (or any other mapping).
    sql_name: []const u8,
    sql_type: SqlType,
    nullable: bool,
    /// Has `= ...` default in the struct definition. Used to mark
    /// auto-populated columns (id, created_at) — we treat them as nullable
    /// when binding INSERT params and re-read them via RETURNING.
    has_default: bool,
    /// Optional SQL default expression, e.g. "unixepoch()" for created_at.
    /// Set via `__schema.defaults.<field> = "..."`. Emitted verbatim into
    /// the CREATE TABLE column-def, wrapped in `DEFAULT (...)`.
    default_sql: ?[]const u8,
    /// True iff this column is the primary key.
    primary_key: bool,
    /// True iff there's a unique index covering just this column (declared
    /// inline through `.unique` shorthand in `__schema.indexes`).
    unique: bool,
};

pub const Index = struct {
    /// SQL index name (auto-generated if not given).
    name: []const u8,
    columns: []const []const u8,
    unique: bool,
};

pub const TableDef = struct {
    table: []const u8,
    primary_key: []const u8,
    columns: []const Column,
    indexes: []const Index,
};

/// Compute the default table name for a struct. Takes the *last segment* of
/// the fully-qualified name (so `models.User` → `User`), lowercases, and
/// appends `s`. Override via `__schema.table` for irregular plurals.
fn defaultTableName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // last `.`-segment
    comptime var last_dot: usize = 0;
    inline for (full, 0..) |c, i| if (c == '.') {
        last_dot = i + 1;
    };
    const short = full[last_dot..];
    // Build the lowercased + "s"-suffixed name into a *fixed-size const* so
    // the resulting slice can survive into runtime code (not a pointer to a
    // comptime var).
    const N = short.len + 1;
    const result: [N]u8 = comptime blk: {
        var tmp: [N]u8 = undefined;
        for (short, 0..) |c, i| tmp[i] = std.ascii.toLower(c);
        tmp[short.len] = 's';
        break :blk tmp;
    };
    // Promote to a static const via a generic helper so the slice points at
    // module-level data.
    return constSlice(&result);
}

/// Wrap a fixed-size const array reference into `[]const u8`. The argument
/// must point at a comptime-known const array; the returned slice is safe
/// to use at runtime because Zig will promote the array to module-level
/// static data.
fn constSlice(comptime ptr: anytype) []const u8 {
    return Statify(@TypeOf(ptr.*), ptr.*).slice();
}

/// Promote a comptime-known value of array type into a module-level const,
/// returning a struct that exposes a stable runtime pointer to it. The
/// trick is that the `T` and `v` are part of the generic instantiation, so
/// they're frozen into the resulting type's namespace — no "mutable not
/// accessible" boundary crossing.
fn Statify(comptime T: type, comptime v: T) type {
    return struct {
        const data: T = v;
        fn slice() []const std.meta.Elem(T) {
            return &data;
        }
        fn ptr() *const T {
            return &data;
        }
    };
}

const TypeMapping = struct { sql_type: SqlType, nullable: bool };

/// Map a Zig field type to its SQL representation. Pure values, no `type`
/// fields, so the result can flow into runtime code if needed.
fn sqlTypeOf(comptime T: type) TypeMapping {
    return switch (@typeInfo(T)) {
        .optional => |o| .{ .sql_type = sqlTypeOf(o.child).sql_type, .nullable = true },
        .int => .{ .sql_type = .integer, .nullable = false },
        .float => .{ .sql_type = .real, .nullable = false },
        .bool => .{ .sql_type = .integer, .nullable = false },
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) {
                break :blk .{ .sql_type = .text, .nullable = false };
            }
            @compileError("sqlTypeOf: only []const u8 pointers are mappable, got " ++ @typeName(T));
        },
        .@"enum" => .{ .sql_type = .integer, .nullable = false },
        else => @compileError("sqlTypeOf: unsupported field type " ++ @typeName(T)),
    };
}

/// Variant of `sqlTypeOf` that consults `T.__schema.enums` for the named
/// field. When the field is an enum AND the model declares a string mapping
/// for it, we treat the column as TEXT instead of INTEGER.
fn sqlTypeOfField(comptime T: type, comptime FieldT: type, comptime field_name: []const u8) TypeMapping {
    const mapping = sqlTypeOf(FieldT);
    if (mapping.sql_type != .integer) return mapping;
    // Check if this field is a string-mapped enum.
    if (!isEnumLike(FieldT)) return mapping;
    if (enumStringsLookup(T, field_name) == null) return mapping;
    return .{ .sql_type = .text, .nullable = mapping.nullable };
}

/// True if the type is an enum (or an optional enum).
fn isEnumLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"enum" => true,
        .optional => |o| switch (@typeInfo(o.child)) {
            .@"enum" => true,
            else => false,
        },
        else => false,
    };
}

/// Returns the enum-to-string mapping struct for the field, or null if not
/// declared. We just need to know "is there one" — the actual lookup is
/// performed at the bind/read site in query.zig.
pub fn enumStringsLookup(comptime T: type, comptime field_name: []const u8) ?type {
    if (!hasDecl(T, "__schema")) return null;
    const s = T.__schema;
    if (!@hasField(@TypeOf(s), "enums")) return null;
    const enums = s.enums;
    if (!@hasField(@TypeOf(enums), field_name)) return null;
    return @TypeOf(@field(enums, field_name));
}

/// Convert an enum value to its mapped TEXT representation. Compile error if
/// `__schema.enums.<field>` doesn't have an entry for the value's tag name.
pub fn enumToText(comptime T: type, comptime field_name: []const u8, value: anytype) []const u8 {
    const E = @TypeOf(value);
    const s = T.__schema;
    const map = @field(s.enums, field_name);
    inline for (@typeInfo(E).@"enum".fields) |ef| {
        if (@intFromEnum(value) == ef.value) {
            if (!@hasField(@TypeOf(map), ef.name)) {
                @compileError("__schema.enums." ++ field_name ++ " missing entry for ." ++ ef.name);
            }
            return @field(map, ef.name);
        }
    }
    unreachable;
}

/// Convert a TEXT row value back into an enum variant. Returns
/// `error.UnknownEnumVariant` if the DB has a value we don't recognise.
pub fn enumFromText(comptime T: type, comptime field_name: []const u8, comptime E: type, text: []const u8) !E {
    const s = T.__schema;
    const map = @field(s.enums, field_name);
    inline for (@typeInfo(E).@"enum".fields) |ef| {
        if (!@hasField(@TypeOf(map), ef.name)) {
            @compileError("__schema.enums." ++ field_name ++ " missing entry for ." ++ ef.name);
        }
        const mapped: []const u8 = @field(map, ef.name);
        if (std.mem.eql(u8, text, mapped)) return @enumFromInt(ef.value);
    }
    return error.UnknownEnumVariant;
}

/// True if the struct has a public declaration named `name`.
fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(T, name);
}

/// Read `__schema.table` if present, else default.
fn schemaTable(comptime T: type) []const u8 {
    if (!hasDecl(T, "__schema")) return defaultTableName(T);
    const s = T.__schema;
    return if (@hasField(@TypeOf(s), "table")) s.table else defaultTableName(T);
}

/// `__schema.defaults = .{ .created_at = "unixepoch()" }` style lookup.
/// Returns null if no entry, the SQL expression otherwise.
fn defaultsLookup(comptime T: type, comptime field_name: []const u8) ?[]const u8 {
    if (!hasDecl(T, "__schema")) return null;
    const s = T.__schema;
    if (!@hasField(@TypeOf(s), "defaults")) return null;
    const defs = s.defaults;
    if (!@hasField(@TypeOf(defs), field_name)) return null;
    return @field(defs, field_name);
}

/// `__schema.columns = .{ .userId = "user_id" }` style override. Returns
/// the SQL column name, or the field name if no override.
fn columnSqlName(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (!hasDecl(T, "__schema")) return field_name;
    const s = T.__schema;
    if (!@hasField(@TypeOf(s), "columns")) return field_name;
    const cols = s.columns;
    if (!@hasField(@TypeOf(cols), field_name)) return field_name;
    return @field(cols, field_name);
}

fn schemaPrimaryKey(comptime T: type) []const u8 {
    if (!hasDecl(T, "__schema")) return "id";
    const s = T.__schema;
    return if (@hasField(@TypeOf(s), "primary_key")) s.primary_key else "id";
}

/// Walk `__schema.indexes`. Format:
///   .{
///       .{ "email", .unique },                     // single-column unique
///       .{ "name", .index },                        // single-column non-unique
///       .{ .{ "user_id", "created_at" }, .index }, // multi-column non-unique
///   }
fn schemaIndexes(comptime T: type) []const Index {
    if (!hasDecl(T, "__schema")) return &.{};
    const s = T.__schema;
    if (!@hasField(@TypeOf(s), "indexes")) return &.{};
    const raw = s.indexes;
    const RawType = @TypeOf(raw);
    const raw_info = @typeInfo(RawType);
    if (raw_info != .@"struct" or !raw_info.@"struct".is_tuple) {
        @compileError("__schema.indexes must be a tuple");
    }
    const n = raw_info.@"struct".fields.len;
    var out: [n]Index = undefined;
    inline for (raw, 0..) |entry, i| {
        const Entry = @TypeOf(entry);
        const ei = @typeInfo(Entry);
        if (ei != .@"struct" or !ei.@"struct".is_tuple or ei.@"struct".fields.len != 2) {
            @compileError("each index entry must be a 2-tuple: { columns, .unique|.index }");
        }
        const cols_raw = entry[0];
        const kind = entry[1];
        const ColsType = @TypeOf(cols_raw);
        const cols: []const []const u8 = blk: {
            // Single column: a string literal like "email".
            if (@typeInfo(ColsType) == .pointer) break :blk &.{cols_raw};
            // Multi-column: .{ "a", "b" } — materialize as a const array.
            const cti = @typeInfo(ColsType);
            if (cti != .@"struct" or !cti.@"struct".is_tuple) {
                @compileError("index columns must be a string or tuple of strings");
            }
            const m = cti.@"struct".fields.len;
            const arr: [m][]const u8 = comptime val: {
                var tmp: [m][]const u8 = undefined;
                for (cols_raw, 0..) |c, j| tmp[j] = c;
                break :val tmp;
            };
            break :blk Statify([m][]const u8, arr).slice();
        };
        const is_unique = kind == .unique;
        // Auto name: "{table}_{cols joined by _}_{idx|unq}"
        const tbl = schemaTable(T);
        const suffix = if (is_unique) "unq" else "idx";
        // Compute final length and emit the name as a fixed-size const array.
        comptime var total_len: usize = tbl.len + 1; // "table_"
        inline for (cols, 0..) |c, idx| {
            if (idx > 0) total_len += 1;
            total_len += c.len;
        }
        total_len += 1 + suffix.len; // "_idx"
        const name_arr: [total_len]u8 = comptime blk: {
            var tmp: [total_len]u8 = undefined;
            var pos: usize = 0;
            for (tbl) |c| {
                tmp[pos] = c;
                pos += 1;
            }
            tmp[pos] = '_';
            pos += 1;
            for (cols, 0..) |c, idx| {
                if (idx > 0) {
                    tmp[pos] = '_';
                    pos += 1;
                }
                for (c) |ch| {
                    tmp[pos] = ch;
                    pos += 1;
                }
            }
            tmp[pos] = '_';
            pos += 1;
            for (suffix) |c| {
                tmp[pos] = c;
                pos += 1;
            }
            break :blk tmp;
        };
        out[i] = .{
            .name = constSlice(&name_arr),
            .columns = cols,
            .unique = is_unique,
        };
    }
    // Promote `out` (built across an inline loop) into module-level static
    // data so the returned slice is a runtime-stable pointer.
    return Statify([n]Index, out).slice();
}

/// Build the `TableDef` for a model struct at comptime.
pub fn tableDef(comptime T: type) TableDef {
    const ti = @typeInfo(T);
    if (ti != .@"struct") @compileError("tableDef: expected struct, got " ++ @typeName(T));
    const fields = ti.@"struct".fields;
    const pk = schemaPrimaryKey(T);

    // Find which non-pk columns also get the "unique" flag from a
    // single-column unique index, so the column metadata can carry it.
    const indexes = schemaIndexes(T);

    var cols: [fields.len]Column = undefined;
    inline for (fields, 0..) |f, i| {
        // Enum fields with a `__schema.enums.<field>` mapping become TEXT
        // columns; otherwise the rule from `sqlTypeOf` applies.
        const t = sqlTypeOfField(T, f.type, f.name);
        const is_pk = std.mem.eql(u8, f.name, pk);
        // Inline unique: a single-column unique index on this column.
        comptime var inline_unique = false;
        inline for (indexes) |ix| {
            if (ix.unique and ix.columns.len == 1 and std.mem.eql(u8, ix.columns[0], f.name)) {
                inline_unique = true;
            }
        }
        const has_default = f.default_value_ptr != null;
        const default_sql: ?[]const u8 = comptime defaultsLookup(T, f.name);
        const sql_name = comptime columnSqlName(T, f.name);
        cols[i] = .{
            .name = f.name,
            .sql_name = sql_name,
            .sql_type = t.sql_type,
            .nullable = t.nullable,
            .has_default = has_default,
            .default_sql = default_sql,
            .primary_key = is_pk,
            .unique = inline_unique,
        };
    }
    return .{
        .table = schemaTable(T),
        .primary_key = pk,
        .columns = Statify([fields.len]Column, cols).slice(),
        .indexes = indexes,
    };
}

// === Tests ===

const testing = std.testing;

const SampleUser = struct {
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

const SamplePost = struct {
    id: ?i64 = null,
    user_id: i64,
    title: []const u8,
};

test "tableDef: explicit table + primary key + indexes" {
    const td = comptime tableDef(SampleUser);
    try testing.expectEqualStrings("users", td.table);
    try testing.expectEqualStrings("id", td.primary_key);
    try testing.expectEqual(@as(usize, 5), td.columns.len);

    try testing.expectEqualStrings("id", td.columns[0].name);
    try testing.expectEqual(SqlType.integer, td.columns[0].sql_type);
    try testing.expect(td.columns[0].nullable);
    try testing.expect(td.columns[0].primary_key);
    try testing.expect(td.columns[0].has_default);

    try testing.expectEqualStrings("email", td.columns[1].name);
    try testing.expectEqual(SqlType.text, td.columns[1].sql_type);
    try testing.expect(!td.columns[1].nullable);
    try testing.expect(td.columns[1].unique); // from inline single-col unique index

    try testing.expectEqualStrings("name", td.columns[2].name);
    try testing.expect(!td.columns[2].unique); // non-unique index doesn't set the column flag

    try testing.expectEqual(@as(usize, 2), td.indexes.len);
    try testing.expectEqual(true, td.indexes[0].unique);
    try testing.expectEqualStrings("email", td.indexes[0].columns[0]);
    try testing.expectEqualStrings("users_email_unq", td.indexes[0].name);
    try testing.expectEqualStrings("users_name_idx", td.indexes[1].name);
}

test "tableDef: default table name from struct name" {
    const td = comptime tableDef(SamplePost);
    try testing.expectEqualStrings("sampleposts", td.table); // SamplePost -> sampleposts
    try testing.expectEqualStrings("id", td.primary_key);
    try testing.expectEqual(@as(usize, 3), td.columns.len);
    try testing.expect(td.columns[0].primary_key); // id
    try testing.expect(!td.columns[1].nullable); // user_id is NOT NULL
    try testing.expect(!td.columns[1].primary_key);
}
