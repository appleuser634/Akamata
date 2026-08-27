const std = @import("std");
const am = @import("akamata");

const NullableModel = struct {
    id: ?i64 = null,
    n: ?i64 = null,
    s: ?[]const u8 = null,
    pub const __schema = .{ .table = "nullable_models" };
};

test "open in-memory, insert, and read back" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, weight REAL)");
    try db.exec("INSERT INTO t(name, weight) VALUES ('alice', 1.5)");

    var stmt = try db.prepare("INSERT INTO t(name, weight) VALUES (?, ?) RETURNING id");
    try stmt.bindAll(.{ @as([]const u8, "bob"), @as(f64, 2.5) });
    const Row = struct { id: i64 };
    const row = try stmt.fetchOne(Row);
    try std.testing.expect(row.id >= 1);
    stmt.deinit();

    var sel = try db.prepare("SELECT id, name, weight FROM t ORDER BY id");
    defer sel.deinit();
    var seen: usize = 0;
    while ((try sel.step()) == .row) {
        const r = try sel.readRow(struct { id: i64, name: []const u8, weight: f64 });
        try std.testing.expect(r.id >= 1);
        try std.testing.expect(r.weight > 0);
        try std.testing.expect(r.name.len > 0);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "execAll runs multiple statements" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();

    try db.execAll(
        \\CREATE TABLE a (x INTEGER);
        \\CREATE TABLE b (y TEXT);
        \\INSERT INTO a VALUES (1);
        \\INSERT INTO a VALUES (2);
    );

    var stmt = try db.prepare("SELECT COUNT(*) FROM a");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i64, 2), try stmt.columnInt(0));
}

test "execAll preserves semicolons in strings and trigger bodies" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    try db.execAll(
        \\CREATE TABLE source (value TEXT);
        \\CREATE TABLE audit (value TEXT);
        \\CREATE TRIGGER source_audit AFTER INSERT ON source BEGIN
        \\  INSERT INTO audit(value) VALUES (NEW.value);
        \\END;
        \\INSERT INTO source(value) VALUES ('a;b');
    );
    var stmt = try db.prepare("SELECT value FROM audit");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expectEqualStrings("a;b", try stmt.columnText(0));
}

test "columnIsNull distinguishes SQL NULL from zero and empty text" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE nullable (n INTEGER, s TEXT)");
    try db.exec("INSERT INTO nullable VALUES (NULL, NULL), (0, '')");
    var stmt = try db.prepare("SELECT n, s FROM nullable ORDER BY rowid");
    defer stmt.deinit();
    _ = try stmt.step();
    try std.testing.expect(try stmt.columnIsNull(0));
    try std.testing.expect(try stmt.columnIsNull(1));
    _ = try stmt.step();
    try std.testing.expect(!try stmt.columnIsNull(0));
    try std.testing.expect(!try stmt.columnIsNull(1));
}

test "model repository preserves optional NULL values" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE nullable_models (id INTEGER PRIMARY KEY, n INTEGER, s TEXT)");
    try db.exec("INSERT INTO nullable_models(id, n, s) VALUES (1, NULL, NULL), (2, 0, '')");
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const Models = am.model.repo(NullableModel);
    const null_row = (try Models.find(db, arena_state.allocator(), 1)).?;
    try std.testing.expect(null_row.n == null);
    try std.testing.expect(null_row.s == null);
    const value_row = (try Models.find(db, arena_state.allocator(), 2)).?;
    try std.testing.expectEqual(@as(?i64, 0), value_row.n);
    try std.testing.expect(value_row.s != null);
    try std.testing.expectEqualStrings("", value_row.s.?);
}

test "explicit transaction rolls back unless committed" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE tx_test (id INTEGER)");
    {
        var tx = try db.begin();
        defer tx.deinit();
        try tx.exec("INSERT INTO tx_test VALUES (1)");
    }
    var count = try db.prepare("SELECT count(*) FROM tx_test");
    defer count.deinit();
    _ = try count.step();
    try std.testing.expectEqual(@as(i64, 0), try count.columnInt(0));
}

test "database pool leases independent handles" {
    const alloc = std.testing.allocator;
    const first = try am.db.openSqlite(alloc, ":memory:");
    const second = try am.db.openSqlite(alloc, ":memory:");
    var pool = try am.db.Pool.init(alloc, &.{ first, second });
    defer pool.deinit();
    var a = try pool.acquire();
    var b = try pool.acquire();
    try std.testing.expect(a.db.ptr != b.db.ptr);
    a.deinit();
    b.deinit();
}
test "byte arrays, pointers, and slices bind their complete value" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE bytes (kind TEXT, value TEXT)");

    var mutable: [64]u8 = [_]u8{'x'} ** 64;
    const direct: [4]u8 = .{ 'a', 'b', 'c', 'd' };
    const mutable_slice: []u8 = mutable[0..5];
    const const_slice: []const u8 = mutable[0..7];
    var stmt = try db.prepare("INSERT INTO bytes VALUES (?, ?), (?, ?), (?, ?), (?, ?)");
    defer stmt.deinit();
    try stmt.bindAll(.{ "array", direct, "pointer", &mutable, "mutable_slice", mutable_slice, "const_slice", const_slice });
    _ = try stmt.step();

    var rows = try db.prepare("SELECT length(value) FROM bytes ORDER BY rowid");
    defer rows.deinit();
    const expected = [_]i64{ 4, 64, 5, 7 };
    for (expected) |length| {
        try std.testing.expectEqual(am.db.StepResult.row, try rows.step());
        try std.testing.expectEqual(length, try rows.columnInt(0));
    }
}
