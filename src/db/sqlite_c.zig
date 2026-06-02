const std = @import("std");

// Isolated @cImport for sqlite3. Build script links sqlite3.c via addCSourceFile.
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_OK = c.SQLITE_OK;
pub const SQLITE_ROW = c.SQLITE_ROW;
pub const SQLITE_DONE = c.SQLITE_DONE;

/// Returns SQLITE_TRANSIENT. Provided by akamata_sqlite_shim.c because
/// Zig 0.16 rejects `@ptrFromInt` of -1 to a function pointer type.
pub extern fn akamata_sqlite_transient() c.sqlite3_destructor_type;

pub inline fn sqliteTransient() c.sqlite3_destructor_type {
    return akamata_sqlite_transient();
}
