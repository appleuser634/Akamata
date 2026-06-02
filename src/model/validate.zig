// Validation rules. Read at comptime from `__schema.validates`, applied at
// runtime via `validate(model, arena) []ValidationError`.
//
// Declaration looks like:
//
//     pub const __schema = .{
//         .validates = .{
//             .email = .{ rule.required, rule.max_len(255), rule.format(.email) },
//             .name  = .{ rule.required, rule.max_len(80) },
//             .age   = .{ rule.range(0, 150) },
//             .bio   = .{ rule.min_len(0), rule.max_len(2000) },
//         },
//     };
//
// Where `rule` is `@import("akamata").model.rule` — a namespace of small
// constructors. Rules carry their parameters as enum-tagged values so the
// engine can interpret them without `@TypeOf` switching per rule type.

const std = @import("std");

pub const Format = enum { email, url, alphanumeric };

/// User-supplied validator for text fields.
/// Returning `null` means "OK"; a non-null slice is the error message and
/// is *not* duplicated by the framework (use the supplied `arena` if you
/// need to allocate).
pub const TextCustomFn = *const fn (value: []const u8, arena: std.mem.Allocator) ?[]const u8;

/// User-supplied validator for integer fields.
pub const IntCustomFn = *const fn (value: i64, arena: std.mem.Allocator) ?[]const u8;

/// Tagged rule. `validate.zig` interprets `kind` at runtime.
pub const Rule = struct {
    kind: Kind,
    int_a: i64 = 0,
    int_b: i64 = 0,
    format: Format = .email,
    text_custom: ?TextCustomFn = null,
    int_custom: ?IntCustomFn = null,

    pub const Kind = enum {
        required,
        min_len,
        max_len,
        range,
        format,
        /// Calls `text_custom` for `[]const u8` (or optional thereof) fields.
        custom_text,
        /// Calls `int_custom` for integer (or optional integer) fields.
        custom_int,
    };
};

// === Rule constructors (use through `am.model.rule`) ===
pub const rule = struct {
    pub const required = Rule{ .kind = .required };

    pub fn min_len(n: usize) Rule {
        return .{ .kind = .min_len, .int_a = @intCast(n) };
    }
    pub fn max_len(n: usize) Rule {
        return .{ .kind = .max_len, .int_a = @intCast(n) };
    }
    pub fn range(lo: i64, hi: i64) Rule {
        return .{ .kind = .range, .int_a = lo, .int_b = hi };
    }
    pub fn format(f: Format) Rule {
        return .{ .kind = .format, .format = f };
    }
    /// User-defined check for a text field. The function returns null on
    /// success or an error message on failure.
    pub fn custom(f: TextCustomFn) Rule {
        return .{ .kind = .custom_text, .text_custom = f };
    }
    /// User-defined check for an integer field.
    pub fn customInt(f: IntCustomFn) Rule {
        return .{ .kind = .custom_int, .int_custom = f };
    }
};

pub const ValidationError = struct {
    field: []const u8,
    rule: Rule.Kind,
    message: []const u8,
};

/// Apply all validation rules declared in `T.__schema.validates` to `value`.
/// Returns a slice of errors (empty = OK). Allocated in `arena` so the
/// caller can drop everything by deinit-ing the arena.
pub fn validate(comptime T: type, value: T, arena: std.mem.Allocator) ![]ValidationError {
    return validateAny(T, value, arena);
}

/// Run T's schema validators against `value` even when `value` is not of
/// type T — useful for "projection" types where the original struct's
/// non-optional fields have been widened to optional so a permissive JSON
/// parser can fill missing fields with null. Validators look up fields by
/// name on `value`; the field types only need to be compatible with each
/// applicable rule.
pub fn validateAny(comptime T: type, value: anytype, arena: std.mem.Allocator) ![]ValidationError {
    var errs: std.ArrayList(ValidationError) = .empty;
    if (!@hasDecl(T, "__schema")) return errs.toOwnedSlice(arena);
    const s = T.__schema;
    if (!@hasField(@TypeOf(s), "validates")) return errs.toOwnedSlice(arena);
    const v = s.validates;

    inline for (@typeInfo(@TypeOf(v)).@"struct".fields) |field_decl| {
        const field_name = field_decl.name;
        const rules_tuple = @field(v, field_name);
        const RulesType = @TypeOf(rules_tuple);
        if (@typeInfo(RulesType) != .@"struct" or !@typeInfo(RulesType).@"struct".is_tuple) {
            @compileError("__schema.validates." ++ field_name ++ " must be a tuple of rules");
        }
        // The projection type may not carry every schema field (e.g. an
        // input DTO with a subset). Skip silently in that case.
        if (!@hasField(@TypeOf(value), field_name)) continue;
        const field_value = @field(value, field_name);

        inline for (rules_tuple) |r| {
            try applyRule(field_name, field_value, r, arena, &errs);
        }
    }
    return errs.toOwnedSlice(arena);
}

fn applyRule(
    comptime field_name: []const u8,
    value: anytype,
    r: Rule,
    arena: std.mem.Allocator,
    errs: *std.ArrayList(ValidationError),
) !void {
    const V = @TypeOf(value);
    const vi = @typeInfo(V);

    switch (r.kind) {
        .required => {
            // Fail if optional and null, OR slice and empty.
            if (vi == .optional) {
                if (value == null) {
                    try errs.append(arena, .{
                        .field = field_name,
                        .rule = .required,
                        .message = "is required",
                    });
                    return;
                }
            }
            if (vi == .pointer and vi.pointer.size == .slice and vi.pointer.child == u8) {
                if (value.len == 0) {
                    try errs.append(arena, .{
                        .field = field_name,
                        .rule = .required,
                        .message = "is required",
                    });
                }
            }
        },
        .min_len, .max_len => {
            // Optional null = "field not supplied" → skip the length rule.
            // Use `required` if you want missing-ness to fail. This mirrors
            // the PATCH semantic: clients omit fields they don't want to
            // change, and we don't want min_len(1) to spuriously fire.
            const len = blk: {
                if (vi == .optional) {
                    if (value == null) return;
                    const inner = value.?;
                    const II = @TypeOf(inner);
                    const ii = @typeInfo(II);
                    if (ii == .pointer and ii.pointer.size == .slice and ii.pointer.child == u8) {
                        break :blk inner.len;
                    }
                    return; // not a string-ish field; rule doesn't apply
                }
                if (vi == .pointer and vi.pointer.size == .slice and vi.pointer.child == u8) {
                    break :blk value.len;
                }
                return; // not a string-ish field
            };
            if (r.kind == .min_len and len < @as(usize, @intCast(r.int_a))) {
                const msg = try std.fmt.allocPrint(arena, "must be at least {d} chars", .{r.int_a});
                try errs.append(arena, .{ .field = field_name, .rule = .min_len, .message = msg });
            }
            if (r.kind == .max_len and len > @as(usize, @intCast(r.int_a))) {
                const msg = try std.fmt.allocPrint(arena, "must be at most {d} chars", .{r.int_a});
                try errs.append(arena, .{ .field = field_name, .rule = .max_len, .message = msg });
            }
        },
        .range => {
            // Pull numeric value out, skipping null optionals.
            const num_opt: ?i64 = blk: {
                if (vi == .optional) {
                    if (value == null) break :blk null;
                    break :blk asI64(value.?);
                }
                break :blk asI64(value);
            };
            if (num_opt) |n| {
                if (n < r.int_a or n > r.int_b) {
                    const msg = try std.fmt.allocPrint(arena, "must be between {d} and {d}", .{ r.int_a, r.int_b });
                    try errs.append(arena, .{ .field = field_name, .rule = .range, .message = msg });
                }
            }
        },
        .format => {
            const text: ?[]const u8 = blk: {
                if (vi == .optional) {
                    if (value == null) break :blk null;
                    const inner = value.?;
                    const II = @TypeOf(inner);
                    const ii = @typeInfo(II);
                    if (ii == .pointer and ii.pointer.size == .slice and ii.pointer.child == u8) {
                        break :blk inner;
                    }
                    return;
                }
                if (vi == .pointer and vi.pointer.size == .slice and vi.pointer.child == u8) {
                    break :blk value;
                }
                return;
            };
            if (text) |s| {
                if (!matchesFormat(s, r.format)) {
                    const fmt_name = @tagName(r.format);
                    const msg = try std.fmt.allocPrint(arena, "is not a valid {s}", .{fmt_name});
                    try errs.append(arena, .{ .field = field_name, .rule = .format, .message = msg });
                }
            }
        },
        .custom_text => {
            const fn_ptr = r.text_custom orelse return;
            const text: ?[]const u8 = blk: {
                if (vi == .optional) {
                    if (value == null) break :blk null;
                    const inner = value.?;
                    const II = @TypeOf(inner);
                    const ii = @typeInfo(II);
                    if (ii == .pointer and ii.pointer.size == .slice and ii.pointer.child == u8) {
                        break :blk inner;
                    }
                    return;
                }
                if (vi == .pointer and vi.pointer.size == .slice and vi.pointer.child == u8) {
                    break :blk value;
                }
                return; // not a string field
            };
            if (text) |s| {
                if (fn_ptr(s, arena)) |msg| {
                    try errs.append(arena, .{ .field = field_name, .rule = .custom_text, .message = msg });
                }
            }
        },
        .custom_int => {
            const fn_ptr = r.int_custom orelse return;
            const n: ?i64 = blk: {
                if (vi == .optional) {
                    if (value == null) break :blk null;
                    break :blk asI64(value.?);
                }
                break :blk asI64(value);
            };
            if (n) |x| {
                if (fn_ptr(x, arena)) |msg| {
                    try errs.append(arena, .{ .field = field_name, .rule = .custom_int, .message = msg });
                }
            }
        },
    }
}

fn asI64(v: anytype) ?i64 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int, .comptime_int => @intCast(v),
        .float, .comptime_float => @intFromFloat(v),
        .bool => if (v) 1 else 0,
        else => null,
    };
}

fn matchesFormat(s: []const u8, f: Format) bool {
    return switch (f) {
        .email => isLikelyEmail(s),
        .url => std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://"),
        .alphanumeric => for (s) |c| {
            if (!std.ascii.isAlphanumeric(c)) break false;
        } else true,
    };
}

/// Minimal "looks like an email" check. We deliberately don't try to
/// implement RFC 5322 — anyone who needs that should plug in a custom rule.
fn isLikelyEmail(s: []const u8) bool {
    if (s.len < 3) return false;
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at == s.len - 1) return false;
    // domain has at least one dot
    return std.mem.indexOfScalar(u8, s[at + 1 ..], '.') != null;
}

// === Tests ===

const testing = std.testing;

const User = struct {
    id: ?i64 = null,
    email: []const u8,
    name: []const u8,
    age: ?i32 = null,
    bio: []const u8 = "",

    pub const __schema = .{
        .validates = .{
            .email = .{ rule.required, rule.max_len(255), rule.format(.email) },
            .name = .{ rule.required, rule.min_len(2), rule.max_len(80) },
            .age = .{ rule.range(0, 150) },
            .bio = .{ rule.max_len(20) },
        },
    };
};

test "validate: all rules pass" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const errs = try validate(User, .{
        .email = "user@example.com",
        .name = "alice",
        .age = 30,
        .bio = "hello",
    }, arena_state.allocator());
    try testing.expectEqual(@as(usize, 0), errs.len);
}

test "validate: required fails on empty string and null" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const errs = try validate(User, .{
        .email = "", // required
        .name = "", // required + min_len
        .age = 200, // out of range
        .bio = "this bio is definitely longer than 20 chars", // max_len
    }, arena_state.allocator());
    // Expect: email required + email format, name required, age range, bio max_len
    // = at least 5 distinct errors
    try testing.expect(errs.len >= 4);

    var saw_email_required = false;
    var saw_age_range = false;
    var saw_bio_max = false;
    for (errs) |e| {
        if (std.mem.eql(u8, e.field, "email") and e.rule == .required) saw_email_required = true;
        if (std.mem.eql(u8, e.field, "age") and e.rule == .range) saw_age_range = true;
        if (std.mem.eql(u8, e.field, "bio") and e.rule == .max_len) saw_bio_max = true;
    }
    try testing.expect(saw_email_required);
    try testing.expect(saw_age_range);
    try testing.expect(saw_bio_max);
}

test "validate: format=email" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const errs = try validate(User, .{
        .email = "not-an-email",
        .name = "bob",
        .age = 20,
    }, arena_state.allocator());
    var saw_format = false;
    for (errs) |e| if (e.rule == .format and std.mem.eql(u8, e.field, "email")) {
        saw_format = true;
    };
    try testing.expect(saw_format);
}

test "validate: model without __schema returns no errors" {
    const Plain = struct { name: []const u8 };
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const errs = try validate(Plain, .{ .name = "x" }, arena_state.allocator());
    try testing.expectEqual(@as(usize, 0), errs.len);
}

// === Custom validators ===

fn requireInternalDomain(value: []const u8, arena: std.mem.Allocator) ?[]const u8 {
    _ = arena;
    if (!std.mem.endsWith(u8, value, "@acme.co")) {
        return "must be an acme.co email";
    }
    return null;
}

fn requireEvenAge(value: i64, arena: std.mem.Allocator) ?[]const u8 {
    _ = arena;
    if (@rem(value, 2) != 0) return "must be even (for the test)";
    return null;
}

const CustomUser = struct {
    email: []const u8,
    age: ?i32 = null,

    pub const __schema = .{
        .validates = .{
            .email = .{ rule.required, rule.custom(requireInternalDomain) },
            .age = .{ rule.customInt(requireEvenAge) },
        },
    };
};

test "validate: custom text validator passes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const errs = try validate(CustomUser, .{ .email = "x@acme.co", .age = 30 }, arena_state.allocator());
    try testing.expectEqual(@as(usize, 0), errs.len);
}

test "validate: custom text validator fails with the supplied message" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const errs = try validate(CustomUser, .{ .email = "x@evil.com", .age = 30 }, arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), errs.len);
    try testing.expectEqualStrings("email", errs[0].field);
    try testing.expectEqual(Rule.Kind.custom_text, errs[0].rule);
    try testing.expectEqualStrings("must be an acme.co email", errs[0].message);
}

test "validate: custom int validator fails on odd value" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const errs = try validate(CustomUser, .{ .email = "x@acme.co", .age = 31 }, arena_state.allocator());
    try testing.expectEqual(@as(usize, 1), errs.len);
    try testing.expectEqualStrings("age", errs[0].field);
    try testing.expectEqual(Rule.Kind.custom_int, errs[0].rule);
}
