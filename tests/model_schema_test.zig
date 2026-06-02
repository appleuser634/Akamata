// Smoke test for the public `am.model` namespace: ensure users can introspect
// their model structs through the framework's public API.

const std = @import("std");
const am = @import("akamata");

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
        },
    };
};

const Post = struct {
    id: ?i64 = null,
    user_id: i64,
    title: []const u8,
    body: []const u8,
    published: bool = false,
};

test "am.model.tableDef: explicit table and unique index" {
    const td = comptime am.model.tableDef(User);
    try std.testing.expectEqualStrings("users", td.table);
    try std.testing.expectEqualStrings("id", td.primary_key);
    try std.testing.expectEqual(@as(usize, 5), td.columns.len);
    // email column should carry unique=true from the inline single-col unique index
    var found_email = false;
    for (td.columns) |c| {
        if (std.mem.eql(u8, c.name, "email")) {
            try std.testing.expect(c.unique);
            try std.testing.expectEqual(am.model.SqlType.text, c.sql_type);
            try std.testing.expect(!c.nullable);
            found_email = true;
        }
    }
    try std.testing.expect(found_email);
}

test "am.model.tableDef: default table name + bool maps to integer" {
    const td = comptime am.model.tableDef(Post);
    try std.testing.expectEqualStrings("posts", td.table); // Post -> posts
    // Last column is `published: bool = false` -> INTEGER, has_default=true
    const published = td.columns[td.columns.len - 1];
    try std.testing.expectEqualStrings("published", published.name);
    try std.testing.expectEqual(am.model.SqlType.integer, published.sql_type);
    try std.testing.expect(published.has_default);
    try std.testing.expect(!published.nullable);
}
