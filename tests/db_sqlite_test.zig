const std = @import("std");
const am = @import("akamata");

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
