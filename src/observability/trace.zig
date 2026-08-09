//! Allocation-free, request-scoped timing aggregates and lightweight spans.
const std = @import("std");
const clock = @import("clock.zig");

pub const Backend = enum(u8) { sqlite, d1, turso, other };
pub const DbOperation = enum(u8) { query, exec };
pub const SpanKind = enum(u8) { app, db, http, storage, serialize, framework };

pub const SpanRecord = struct {
    name: []const u8,
    kind: SpanKind,
    duration_ns: u64,
    parent: ?u8,
};

pub const TraceContext = struct {
    pub const max_spans = 24;
    request_id_buf: [64]u8 = undefined,
    request_id_len: u8 = 0,
    route_pattern: ?[]const u8 = null,
    start_ns: u64 = 0,
    duration_ns: u64 = 0,
    db_ns: u64 = 0,
    db_queries: u32 = 0,
    db_execs: u32 = 0,
    db_errors: u32 = 0,
    db_backend_operations: [4]u32 = .{ 0, 0, 0, 0 },
    db_backend_operation_counts: [4][2]u32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
    db_backend_operation_ns: [4][2]u64 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
    db_backend_errors: [4]u32 = .{ 0, 0, 0, 0 },
    db_backend_ns: [4]u64 = .{ 0, 0, 0, 0 },
    outbound_http_ns: u64 = 0,
    outbound_http_requests: u32 = 0,
    outbound_http_errors: u32 = 0,
    storage_ns: u64 = 0,
    storage_operations: u32 = 0,
    spans: [max_spans]SpanRecord = undefined,
    span_count: u8 = 0,
    active_span: ?u8 = null,
    dropped_spans: u16 = 0,

    pub fn begin(self: *TraceContext) void {
        self.start_ns = clock.monotonicNs();
    }
    pub fn finish(self: *TraceContext) void {
        self.duration_ns = clock.elapsedNs(self.start_ns);
    }
    pub fn requestId(self: *const TraceContext) ?[]const u8 {
        if (self.request_id_len == 0) return null;
        return self.request_id_buf[0..self.request_id_len];
    }
    pub fn setRequestId(self: *TraceContext, value: []const u8) void {
        const n = @min(value.len, self.request_id_buf.len);
        @memcpy(self.request_id_buf[0..n], value[0..n]);
        self.request_id_len = @intCast(n);
    }
    pub fn startSpan(self: *TraceContext, name: []const u8) Span {
        const start = clock.monotonicNs();
        if (self.span_count >= max_spans) {
            self.dropped_spans +|= 1;
            return .{ .trace = self, .start_ns = start, .index = null, .kind = classify(name) };
        }
        const index = self.span_count;
        self.span_count += 1;
        self.spans[index] = .{ .name = name, .kind = classify(name), .duration_ns = 0, .parent = self.active_span };
        self.active_span = index;
        return .{ .trace = self, .start_ns = start, .index = index, .kind = self.spans[index].kind };
    }
    pub fn recordDb(self: *TraceContext, backend: Backend, operation: DbOperation, elapsed_ns: u64, failed: bool) void {
        self.db_ns +|= elapsed_ns;
        const bi = @intFromEnum(backend);
        const oi = @intFromEnum(operation);
        self.db_backend_operations[bi] +|= 1;
        self.db_backend_operation_counts[bi][oi] +|= 1;
        self.db_backend_operation_ns[bi][oi] +|= elapsed_ns;
        self.db_backend_ns[bi] +|= elapsed_ns;
        switch (operation) {
            .query => self.db_queries +|= 1,
            .exec => self.db_execs +|= 1,
        }
        if (failed) {
            self.db_errors +|= 1;
            self.db_backend_errors[bi] +|= 1;
        }
    }
};

pub const Span = struct {
    trace: *TraceContext,
    start_ns: u64,
    index: ?u8,
    kind: SpanKind,
    ended: bool = false,

    pub fn end(self: *Span) void {
        if (self.ended) return;
        self.ended = true;
        const elapsed = clock.elapsedNs(self.start_ns);
        if (self.index) |i| {
            self.trace.spans[i].duration_ns = elapsed;
            self.trace.active_span = self.trace.spans[i].parent;
        }
        switch (self.kind) {
            .storage => {
                self.trace.storage_ns +|= elapsed;
                self.trace.storage_operations +|= 1;
            },
            .http => {
                self.trace.outbound_http_ns +|= elapsed;
                self.trace.outbound_http_requests +|= 1;
            },
            else => {},
        }
    }
};

fn classify(name: []const u8) SpanKind {
    if (std.mem.startsWith(u8, name, "db.")) return .db;
    if (std.mem.startsWith(u8, name, "http.") or std.mem.startsWith(u8, name, "fetch.")) return .http;
    if (std.mem.startsWith(u8, name, "r2.") or std.mem.startsWith(u8, name, "storage.")) return .storage;
    if (std.mem.startsWith(u8, name, "serialize")) return .serialize;
    if (std.mem.startsWith(u8, name, "framework") or std.mem.startsWith(u8, name, "middleware")) return .framework;
    return .app;
}

test "simple and nested spans" {
    var t: TraceContext = .{};
    var outer = t.startSpan("app");
    var inner = t.startSpan("r2.put");
    inner.end();
    outer.end();
    try std.testing.expectEqual(@as(u8, 2), t.span_count);
    try std.testing.expectEqual(@as(?u8, 0), t.spans[1].parent);
    try std.testing.expectEqual(@as(u32, 1), t.storage_operations);
}
