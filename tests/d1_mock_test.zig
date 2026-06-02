const std = @import("std");
const am = @import("akamata");

// On native builds, the workers-only d1 backend isn't compiled in.
// This test exists to prove the Value abstraction and the shared
// `Db` vtable can round-trip values through any backend; we
// exercise SqliteBackend here, which uses the same vtable shape.

test "Value union round-trips through Db vtable" {
    const alloc = std.testing.allocator;
    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();

    try db.exec("CREATE TABLE v (i INTEGER, f REAL, t TEXT, b BLOB)");
    var ins = try db.prepare("INSERT INTO v(i,f,t,b) VALUES (?,?,?,?)");
    defer ins.deinit();
    try ins.bind(1, am.db.Value{ .int = 42 });
    try ins.bind(2, am.db.Value{ .float = 3.14 });
    try ins.bind(3, am.db.Value{ .text = "hello" });
    try ins.bind(4, am.db.Value{ .blob = "\x00\x01\x02" });
    _ = try ins.step();

    var sel = try db.prepare("SELECT i, f, t, b FROM v");
    defer sel.deinit();
    _ = try sel.step();
    try std.testing.expectEqual(@as(i64, 42), try sel.columnInt(0));
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), try sel.columnFloat(1), 0.001);
    try std.testing.expectEqualStrings("hello", try sel.columnText(2));
    try std.testing.expectEqualStrings("\x00\x01\x02", try sel.columnBlob(3));
}
