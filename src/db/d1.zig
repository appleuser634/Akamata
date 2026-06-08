const std = @import("std");
const db_mod = @import("db.zig");

// Cloudflare D1 backend for Workers (wasm32-freestanding).
//
// **Implementation**: JavaScript Promise Integration (JSPI).
//
// D1's runtime API is async (every prepare/bind/all is a Promise on the JS
// side), but Akamata handlers expect synchronous semantics so the same code
// works on SQLite/Turso/D1. JSPI is the V8 feature that bridges the two:
// the JS host wraps async imports with `new WebAssembly.Suspending(fn)` and
// wraps the wasm entry point with `WebAssembly.promising(handle_fetch)`.
// From Zig's perspective the import looks fully synchronous.
//
// Zig-side code therefore needs **zero special handling** beyond the
// `extern` declarations below. The JS host (deploy/.../worker/index.mjs)
// owns the suspend/resume machinery.
//
// **One suspend per statement.** A JSPI suspend/resume tears down and rebuilds
// the whole wasm call stack, so it is expensive even when the JS function does
// no I/O. Only `d1_run` (run the query, materialise all rows) and `d1_exec`
// actually await; everything else — prepare, bind, step, column reads — is a
// plain synchronous import. `stepStmt` calls `d1_run` lazily on the first
// `step()` (binds land between prepare and the first step), after which row
// iteration is suspend-free. This keeps a multi-row SELECT at a single suspend
// instead of one-per-row.
//
// Backwards compatibility: when an older host doesn't have JSPI wired up
// (or returns the legacy `-2` sentinel from a stub), we still propagate
// `D1Error.BridgeNotImplemented` so handlers fail closed rather than
// quietly seeing zero rows.

pub const D1Error = error{
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
    InvalidHandle,
    /// The Workers JS host doesn't have a JSPI-capable D1 bridge wired up
    /// (e.g. an old Miniflare without `WebAssembly.Suspending` support).
    /// The JS stub returns the sentinel `-2` for every operation so Zig can
    /// detect this and surface a recognisable error.
    BridgeNotImplemented,
};

// Imports provided by the JS host. They're declared with the same int/ptr
// signatures across backends — JSPI works by wrapping these on the JS side
// in `new WebAssembly.Suspending(...)`, so Zig sees a synchronous call.
extern "akamata_d1" fn d1_prepare(sql_ptr: [*]const u8, sql_len: usize) i32;
extern "akamata_d1" fn d1_bind_int64(stmt: i32, idx: i32, value: i64) i32;
extern "akamata_d1" fn d1_bind_double(stmt: i32, idx: i32, value: f64) i32;
extern "akamata_d1" fn d1_bind_text(stmt: i32, idx: i32, ptr: [*]const u8, len: usize) i32;
extern "akamata_d1" fn d1_bind_blob(stmt: i32, idx: i32, ptr: [*]const u8, len: usize) i32;
extern "akamata_d1" fn d1_bind_null(stmt: i32, idx: i32) i32;
/// Async (suspending on the JS side): bind + run the statement, materialising
/// the full result set. Returns row count (>= 0), -2 = bridge not implemented,
/// < -2 = query error. Called lazily by `stepStmt` on the first step.
extern "akamata_d1" fn d1_run(stmt: i32) i32;
/// Synchronous cursor advance over the rows from `d1_run`.
/// Returns: 0 = done, 1 = row, < 0 = error.
extern "akamata_d1" fn d1_step(stmt: i32) i32;
extern "akamata_d1" fn d1_column_int64(stmt: i32, idx: i32) i64;
extern "akamata_d1" fn d1_column_double(stmt: i32, idx: i32) f64;
extern "akamata_d1" fn d1_column_text_len(stmt: i32, idx: i32) usize;
extern "akamata_d1" fn d1_column_text_copy(stmt: i32, idx: i32, out_ptr: [*]u8, out_len: usize) usize;
extern "akamata_d1" fn d1_column_count(stmt: i32) i32;
extern "akamata_d1" fn d1_reset(stmt: i32) void;
extern "akamata_d1" fn d1_finalize(stmt: i32) void;
extern "akamata_d1" fn d1_exec(sql_ptr: [*]const u8, sql_len: usize) i32;

pub const Backend = struct {
    gpa: std.mem.Allocator,

    pub fn open(gpa: std.mem.Allocator) !db_mod.Db {
        const self = try gpa.create(Backend);
        self.* = .{ .gpa = gpa };
        return .{ .ptr = self, .vt = &vtable };
    }

    fn closeBackend(ptr: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        self.gpa.destroy(self);
    }

    fn execBackend(_: *anyopaque, sql: []const u8) anyerror!void {
        const rc = d1_exec(sql.ptr, sql.len);
        return switch (rc) {
            0 => {},
            -2 => D1Error.BridgeNotImplemented,
            else => D1Error.ExecFailed,
        };
    }

    fn prepareBackend(ptr: *anyopaque, sql: []const u8) anyerror!db_mod.Stmt {
        const self: *Backend = @ptrCast(@alignCast(ptr));
        const h = d1_prepare(sql.ptr, sql.len);
        if (h == -2) return D1Error.BridgeNotImplemented;
        if (h < 0) return D1Error.PrepareFailed;
        const s = try self.gpa.create(StmtBackend);
        s.* = .{ .handle = h, .gpa = self.gpa };
        return .{ .ptr = s, .vt = &stmt_vtable };
    }

    const vtable: db_mod.VTable = .{
        .prepare = prepareBackend,
        .exec = execBackend,
        .close = closeBackend,
    };
};

const StmtBackend = struct {
    handle: i32,
    gpa: std.mem.Allocator,
    /// Whether `d1_run` has executed the query yet. The first `step()` runs it
    /// (after all binds), subsequent steps just advance the JS-side cursor.
    ran: bool = false,
};

fn bindStmt(ptr: *anyopaque, idx: usize, v: db_mod.Value) anyerror!void {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    const i: i32 = @intCast(idx);
    const rc: i32 = switch (v) {
        .null_value => d1_bind_null(self.handle, i),
        .int => |x| d1_bind_int64(self.handle, i, x),
        .float => |x| d1_bind_double(self.handle, i, x),
        .text => |s| d1_bind_text(self.handle, i, s.ptr, s.len),
        .blob => |s| d1_bind_blob(self.handle, i, s.ptr, s.len),
    };
    if (rc == -2) return D1Error.BridgeNotImplemented;
    if (rc < 0) return D1Error.BindFailed;
}

fn stepStmt(ptr: *anyopaque) anyerror!db_mod.StepResult {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    // Lazily run the query on the first step (binds have landed by now). This
    // is the one suspending call per statement; d1_step itself is synchronous.
    if (!self.ran) {
        const rc = d1_run(self.handle);
        if (rc == -2) return D1Error.BridgeNotImplemented;
        if (rc < 0) return D1Error.StepFailed;
        self.ran = true;
    }
    const rc = d1_step(self.handle);
    return switch (rc) {
        0 => .done,
        1 => .row,
        else => D1Error.StepFailed,
    };
}

fn columnIntFn(ptr: *anyopaque, idx: usize) anyerror!i64 {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    return d1_column_int64(self.handle, @intCast(idx));
}

fn columnFloatFn(ptr: *anyopaque, idx: usize) anyerror!f64 {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    return d1_column_double(self.handle, @intCast(idx));
}

fn columnTextFn(ptr: *anyopaque, idx: usize) anyerror![]const u8 {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    const len = d1_column_text_len(self.handle, @intCast(idx));
    if (len == 0) return "";
    const buf = try self.gpa.alloc(u8, len);
    const got = d1_column_text_copy(self.handle, @intCast(idx), buf.ptr, len);
    return buf[0..got];
}

fn columnBlobFn(ptr: *anyopaque, idx: usize) anyerror![]const u8 {
    return columnTextFn(ptr, idx);
}

fn columnCountFn(ptr: *anyopaque) usize {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    const n = d1_column_count(self.handle);
    return if (n < 0) 0 else @intCast(n);
}

fn resetStmt(ptr: *anyopaque) anyerror!void {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    d1_reset(self.handle);
    // Re-stepping after a reset must re-run the query.
    self.ran = false;
}

fn deinitStmt(ptr: *anyopaque) void {
    const self: *StmtBackend = @ptrCast(@alignCast(ptr));
    d1_finalize(self.handle);
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

pub fn open(gpa: std.mem.Allocator) !db_mod.Db {
    return Backend.open(gpa);
}
