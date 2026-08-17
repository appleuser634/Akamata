const std = @import("std");
pub const Value = @import("value.zig").Value;
const trace_mod = @import("../observability/trace.zig");
const clock = @import("../observability/clock.zig");

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
    column_is_null: *const fn (ptr: *anyopaque, idx: usize) anyerror!bool,
    column_count: *const fn (ptr: *anyopaque) usize,
    reset: *const fn (ptr: *anyopaque) anyerror!void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub const Stmt = struct {
    ptr: *anyopaque,
    vt: *const StmtVTable,
    trace: ?*trace_mod.TraceContext = null,
    backend: trace_mod.Backend = .other,
    operation_recorded: bool = false,

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

    pub fn step(self: *Stmt) !StepResult {
        if (self.operation_recorded or self.trace == null) return self.vt.step(self.ptr);
        const t0 = clock.monotonicNs();
        const result = self.vt.step(self.ptr) catch |err| {
            self.operation_recorded = true;
            self.trace.?.recordDb(self.backend, .query, clock.elapsedNs(t0), true);
            return err;
        };
        self.operation_recorded = true;
        self.trace.?.recordDb(self.backend, .query, clock.elapsedNs(t0), false);
        return result;
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
    pub fn columnIsNull(self: Stmt, idx: usize) !bool {
        return self.vt.column_is_null(self.ptr, idx);
    }
    pub fn columnCount(self: Stmt) usize {
        return self.vt.column_count(self.ptr);
    }
    pub fn reset(self: *Stmt) !void {
        try self.vt.reset(self.ptr);
        self.operation_recorded = false;
    }
    pub fn deinit(self: Stmt) void {
        self.vt.deinit(self.ptr);
    }

    /// Fetch a single row and map columns to the fields of T in declaration order.
    /// Supported field types: i64/u64/i32/u32/bool/f64/[]const u8.
    pub fn fetchOne(self: *Stmt, comptime T: type) !T {
        const r = try self.step();
        if (r == .done) return DbError.NoRow;
        return try readRow(self.*, T);
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
    backend: trace_mod.Backend = .other,
    trace: ?*trace_mod.TraceContext = null,

    pub fn observed(self: Db, trace: *trace_mod.TraceContext) Db {
        var copy = self;
        copy.trace = trace;
        return copy;
    }

    pub fn prepare(self: Db, sql: []const u8) !Stmt {
        var stmt = try self.vt.prepare(self.ptr, sql);
        stmt.trace = self.trace;
        stmt.backend = self.backend;
        return stmt;
    }
    pub fn exec(self: Db, sql: []const u8) !void {
        if (self.trace == null) return self.vt.exec(self.ptr, sql);
        const t0 = clock.monotonicNs();
        self.vt.exec(self.ptr, sql) catch |err| {
            self.trace.?.recordDb(self.backend, .exec, clock.elapsedNs(t0), true);
            return err;
        };
        self.trace.?.recordDb(self.backend, .exec, clock.elapsedNs(t0), false);
    }
    pub fn execAll(self: Db, script: []const u8) !void {
        // sqlite3_exec is a real script engine and correctly handles trigger
        // bodies whose internal statements are also semicolon-terminated.
        if (self.backend == .sqlite) return self.exec(script);
        // Split only on statement terminators outside SQL strings/comments.
        // A raw split corrupts triggers and values such as 'a;b'.
        var start: usize = 0;
        var i: usize = 0;
        var quote: ?u8 = null;
        var line_comment = false;
        var block_comment = false;
        while (i < script.len) : (i += 1) {
            const ch = script[i];
            const next = if (i + 1 < script.len) script[i + 1] else 0;
            if (line_comment) {
                if (ch == '\n') line_comment = false;
                continue;
            }
            if (block_comment) {
                if (ch == '*' and next == '/') {
                    block_comment = false;
                    i += 1;
                }
                continue;
            }
            if (quote) |q| {
                if (ch == q) {
                    if (next == q) {
                        i += 1;
                    } else quote = null;
                }
                continue;
            }
            if (ch == '-' and next == '-') {
                line_comment = true;
                i += 1;
            } else if (ch == '/' and next == '*') {
                block_comment = true;
                i += 1;
            } else if (ch == '\'' or ch == '"' or ch == '`') {
                quote = ch;
            } else if (ch == ';') {
                const statement = std.mem.trim(u8, script[start..i], " \t\r\n");
                if (statement.len > 0) try self.exec(statement);
                start = i + 1;
            }
        }
        if (quote != null or block_comment) return error.InvalidSqlScript;
        const tail = std.mem.trim(u8, script[start..], " \t\r\n");
        if (tail.len > 0) try self.exec(tail);
    }
    pub fn close(self: Db) void {
        self.vt.close(self.ptr);
    }
};
