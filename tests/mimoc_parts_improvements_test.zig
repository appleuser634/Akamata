const std = @import("std");
const am = @import("akamata");

const Item = struct {
    id: ?i64 = null,
    name: []const u8,
    kind: []const u8,
    pub const __schema = .{ .table = "items", .primary_key = "id" };
};

test "portable utility surface is available" {
    try std.testing.expect(am.crypto.timingSafeEqual("same", "same"));
    try std.testing.expect(am.crypto.sameOrigin("https://parts.example", "HTTPS://PARTS.EXAMPLE"));
    try std.testing.expectEqual(@as(u16, 404), am.errors.map(error.NoRow).status);
    try am.idempotency.validateKey("upload-12345678");
}

test "query builder and arbitrary DTO mapping" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var database = try am.db.openSqlite(std.testing.allocator, ":memory:");
    defer database.close();
    try database.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL)");
    try database.exec("INSERT INTO items(name, kind) VALUES ('one','part'),('two','other'),('three','part')");
    try am.model.repo(Item).updateFields(database, arena, 1, .{ .name = @as([]const u8, "updated") });
    const DTO = struct { id: i64, name: []const u8 };
    var query = try am.model.Query.init(database, arena, "items", "id, name");
    const kind: []const u8 = "part";
    _ = try query.whereEq("kind", kind);
    _ = try query.orderBy("id", .desc);
    _ = query.limit(1).offset(0);
    const rows = try query.fetchAll(DTO);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("three", rows[0].name);
    const raw = try am.db.fetchAll(DTO, database, arena, "SELECT id, name FROM items WHERE id IN (?, ?) ORDER BY id", .{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 2), raw.len);
    try std.testing.expectEqualStrings("updated", raw[0].name);
    try database.ping();
    try am.idempotency.ensureTable(database);
    const hash = am.idempotency.requestHash("POST", "/parts", "{}");
    try std.testing.expectEqual(am.idempotency.Result.claimed, try am.idempotency.claim(database, "parts-create-123", &hash));
    try std.testing.expectEqual(am.idempotency.Result.duplicate, try am.idempotency.claim(database, "parts-create-123", &hash));
}
