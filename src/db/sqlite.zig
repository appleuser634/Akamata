const std = @import("std");
const sc = @import("sqlite_c.zig");
const c = sc.c;
const db_mod = @import("db.zig");

pub const SqliteError = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
    InvalidUtf8,
};

pub const Backend = struct {
    handle: *c.sqlite3,
    gpa: std.mem.Allocator,

    pub fn open(gpa: std.mem.Allocator, path: []const u8) !db_mod.Db {
        const self = try gpa.create(Backend);
        errdefer gpa.destroy(self);
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX | c.SQLITE_OPEN_URI;
        const rc = c.sqlite3_open_v2(path_z.ptr, &handle, flags, null);
        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return SqliteError.OpenFailed;
        }
        self.* = .{ .handle = handle.?, .gpa = gpa };
        _ = c.sqlite3_busy_timeout(self.handle, 5000);
        // Sensible defaults: WAL + foreign keys
        _ = c.sqlite3_exec(self.handle, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;", null, null, null);
        return .{ .ptr = self, .vt = &vtable };
    }

    fn closeBackend(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        _ = c.sqlite3_close(self.handle);
        self.gpa.destroy(self);
    }

    fn execBackend(ptr: *anyopaque, sql: []const u8) anyerror!void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const sql_z = try self.gpa.dupeZ(u8, sql);
        defer self.gpa.free(sql_z);
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql_z.ptr, null, null, &errmsg);
        if (errmsg != null) c.sqlite3_free(errmsg);
        if (rc != c.SQLITE_OK) return SqliteError.ExecFailed;
    }

    fn prepareBackend(ptr: *anyopaque, sql: []const u8) anyerror!db_mod.Stmt {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) return SqliteError.PrepareFailed;
        const s = try self.gpa.create(StmtBackend);
        s.* = .{ .stmt = stmt.?, .gpa = self.gpa };
        return .{ .ptr = s, .vt = &stmt_vtable };
    }

    const vtable: db_mod.VTable = .{
        .prepare = prepareBackend,
        .exec = execBackend,
        .close = closeBackend,
    };
};

const StmtBackend = struct {
    stmt: *c.sqlite3_stmt,
    gpa: std.mem.Allocator,
};

fn bindStmt(ptr: *anyopaque, idx: usize, v: db_mod.Value) anyerror!void {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    const i: c_int = @intCast(idx);
    const rc: c_int = switch (v) {
        .null_value => c.sqlite3_bind_null(self.stmt, i),
        .int => |x| c.sqlite3_bind_int64(self.stmt, i, x),
        .float => |x| c.sqlite3_bind_double(self.stmt, i, x),
        .text => |s| c.sqlite3_bind_text(self.stmt, i, s.ptr, @intCast(s.len), sc.sqliteTransient()),
        .blob => |s| c.sqlite3_bind_blob(self.stmt, i, s.ptr, @intCast(s.len), sc.sqliteTransient()),
    };
    if (rc != c.SQLITE_OK) return SqliteError.BindFailed;
}

fn stepStmt(ptr: *anyopaque) anyerror!db_mod.StepResult {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    const rc = c.sqlite3_step(self.stmt);
    return switch (rc) {
        c.SQLITE_ROW => .row,
        c.SQLITE_DONE => .done,
        else => SqliteError.StepFailed,
    };
}

fn columnIntFn(ptr: *anyopaque, idx: usize) anyerror!i64 {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    return c.sqlite3_column_int64(self.stmt, @intCast(idx));
}

fn columnFloatFn(ptr: *anyopaque, idx: usize) anyerror!f64 {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    return c.sqlite3_column_double(self.stmt, @intCast(idx));
}

fn columnTextFn(ptr: *anyopaque, idx: usize) anyerror![]const u8 {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    const i: c_int = @intCast(idx);
    const txt = c.sqlite3_column_text(self.stmt, i);
    const len = c.sqlite3_column_bytes(self.stmt, i);
    if (txt == null or len <= 0) return "";
    return @as([*]const u8, @ptrCast(txt))[0..@intCast(len)];
}

fn columnBlobFn(ptr: *anyopaque, idx: usize) anyerror![]const u8 {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    const i: c_int = @intCast(idx);
    const blob = c.sqlite3_column_blob(self.stmt, i);
    const len = c.sqlite3_column_bytes(self.stmt, i);
    if (blob == null or len <= 0) return "";
    return @as([*]const u8, @ptrCast(blob))[0..@intCast(len)];
}

fn columnCountFn(ptr: *anyopaque) usize {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    return @intCast(c.sqlite3_column_count(self.stmt));
}

fn resetStmt(ptr: *anyopaque) anyerror!void {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    _ = c.sqlite3_reset(self.stmt);
    _ = c.sqlite3_clear_bindings(self.stmt);
}

fn deinitStmt(ptr: *anyopaque) void {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    _ = c.sqlite3_finalize(self.stmt);
    self.gpa.destroy(self);
}

const stmt_vtable: db_mod.StmtVTable = .{
    .bind = bindStmt,
    .step = stepStmt,
    .column_int = columnIntFn,
    .column_float = columnFloatFn,
    .column_text = columnTextFn,
    .column_blob = columnBlobFn,
    .column_count = columnCountFn,
    .reset = resetStmt,
    .deinit = deinitStmt,
};

pub fn open(gpa: std.mem.Allocator, path: []const u8) !db_mod.Db {
    return Backend.open(gpa, path);
}
