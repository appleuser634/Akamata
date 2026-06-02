const std = @import("std");
pub const Value = @import("value.zig").Value;

pub const DbError = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
    NoRow,
    OutOfMemory,
    InvalidColumn,
    InvalidType,
};

pub const StepResult = enum { row, done };

pub const StmtVTable = struct {
    bind: *const fn (ptr: *anyopaque, idx: usize, v: Value) anyerror!void,
    step: *const fn (ptr: *anyopaque) anyerror!StepResult,
    column_int: *const fn (ptr: *anyopaque, idx: usize) anyerror!i64,
    column_float: *const fn (ptr: *anyopaque, idx: usize) anyerror!f64,
    column_text: *const fn (ptr: *anyopaque, idx: usize) anyerror![]const u8,
    column_blob: *const fn (ptr: *anyopaque, idx: usize) anyerror![]const u8,
    column_count: *const fn (ptr: *anyopaque) usize,
    reset: *const fn (ptr: *anyopaque) anyerror!void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub const Stmt = struct {
    ptr: *anyopaque,
    vt: *const StmtVTable,

    pub fn bind(self: Stmt, idx: usize, v: Value) !void {
        return self.vt.bind(self.ptr, idx, v);
    }

    pub fn bindAll(self: Stmt, args: anytype) !void {
        const ti = @typeInfo(@TypeOf(args));
        if (ti != .@"struct" or !ti.@"struct".is_tuple) @compileError("bindAll: tuple expected");
        comptime var idx: usize = 1;
        inline for (args) |a| {
            try self.bind(idx, Value.fromAny(a));
            idx += 1;
        }
    }

    pub fn step(self: Stmt) !StepResult {
        return self.vt.step(self.ptr);
    }

    pub fn columnInt(self: Stmt, idx: usize) !i64 {
        return self.vt.column_int(self.ptr, idx);
    }
    pub fn columnFloat(self: Stmt, idx: usize) !f64 {
        return self.vt.column_float(self.ptr, idx);
    }
    pub fn columnText(self: Stmt, idx: usize) ![]const u8 {
        return self.vt.column_text(self.ptr, idx);
    }
    pub fn columnBlob(self: Stmt, idx: usize) ![]const u8 {
        return self.vt.column_blob(self.ptr, idx);
    }
    pub fn columnCount(self: Stmt) usize {
        return self.vt.column_count(self.ptr);
    }
    pub fn reset(self: Stmt) !void {
        return self.vt.reset(self.ptr);
    }
    pub fn deinit(self: Stmt) void {
        self.vt.deinit(self.ptr);
    }

    /// Fetch a single row and map columns to the fields of T in declaration order.
    /// Supported field types: i64/u64/i32/u32/bool/f64/[]const u8.
    pub fn fetchOne(self: Stmt, comptime T: type) !T {
        const r = try self.step();
        if (r == .done) return DbError.NoRow;
        return try readRow(self, T);
    }

    pub fn readRow(self: Stmt, comptime T: type) !T {
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("readRow: struct expected");
        var out: T = undefined;
        inline for (info.@"struct".fields, 0..) |f, i| {
            const FT = f.type;
            const fi = @typeInfo(FT);
            switch (fi) {
                .int => @field(out, f.name) = @intCast(try self.columnInt(i)),
                .float => @field(out, f.name) = @floatCast(try self.columnFloat(i)),
                .bool => @field(out, f.name) = (try self.columnInt(i)) != 0,
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) {
                        @field(out, f.name) = try self.columnText(i);
                    } else @compileError("readRow: unsupported pointer type for field " ++ f.name);
                },
                else => @compileError("readRow: unsupported field type " ++ @typeName(FT)),
            }
        }
        return out;
    }
};

pub const VTable = struct {
    prepare: *const fn (ptr: *anyopaque, sql: []const u8) anyerror!Stmt,
    exec: *const fn (ptr: *anyopaque, sql: []const u8) anyerror!void,
    close: *const fn (ptr: *anyopaque) void,
};

pub const Db = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub fn prepare(self: Db, sql: []const u8) !Stmt {
        return self.vt.prepare(self.ptr, sql);
    }
    pub fn exec(self: Db, sql: []const u8) !void {
        return self.vt.exec(self.ptr, sql);
    }
    pub fn execAll(self: Db, script: []const u8) !void {
        // Simple semicolon-split executor for migrations.
        var it = std.mem.splitScalar(u8, script, ';');
        while (it.next()) |raw| {
            const s = std.mem.trim(u8, raw, " \t\r\n");
            if (s.len == 0) continue;
            try self.exec(s);
        }
    }
    pub fn close(self: Db) void {
        self.vt.close(self.ptr);
    }
};
