const std = @import("std");
const am = @import("akamata");

test "am.db.open returns UnknownScheme for garbage URLs" {
    const r = am.db.open(std.testing.allocator, "garbage");
    try std.testing.expectError(error.UnknownScheme, r);
}

test "am.db.open returns UnknownScheme for empty URL" {
    const r = am.db.open(std.testing.allocator, "");
    try std.testing.expectError(error.UnknownScheme, r);
}

test "am.db.open file: works on native and parses path correctly" {
    if (am.backend != .native) return error.SkipZigTest;
    // ":memory:" should be accepted by sqlite — we just check the call succeeds.
    var db = try am.db.open(std.testing.allocator, "file::memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (x INTEGER)");
}

test "am.db.open libsql:// returns a Db without hitting the network" {
    // open() only constructs the backend; it doesn't make a request until the
    // first prepare/exec. So we can verify URL acceptance offline.
    var db = try am.db.open(std.testing.allocator, "libsql://example.turso.io?authToken=fake");
    defer db.close();
    // sanity: vtable is wired
    _ = db.vt.prepare;
}
