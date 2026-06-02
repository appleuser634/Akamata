// Turso / libsql client over Hrana v3 HTTP.
//
// Hrana is request/response (POST /v3/pipeline → JSON), so it slots into the
// existing synchronous `Db` vtable without the 2-pass JS↔Wasm bridge the D1
// backend needs. Works identically on native (TLS via am.http_client) and
// Workers (fetch via am.http_client extern bridge).
//
// Reference: https://github.com/tursodatabase/libsql/blob/main/docs/HRANA_3_SPEC.md

const std = @import("std");
const db_mod = @import("db.zig");
const http_client = @import("../http_client.zig");
const json_mod = @import("../json.zig");

pub const TursoError = error{
    InvalidUrl,
    HttpFailed,
    AuthFailed,
    HranaError,
    BatonMissing,
    InvalidResponse,
    UnsupportedColumnType,
    OutOfMemory,
};

/// Connection options. Either `url` (https://) or shorthand `libsql://...`.
pub const Options = struct {
    /// Either "libsql://host" or "https://host" — both accepted.
    /// Optional `?authToken=...` query parameter is parsed; explicit `auth_token`
    /// takes precedence.
    url: []const u8,
    /// Bearer JWT. Required for Turso Cloud.
    auth_token: ?[]const u8 = null,
};

pub fn open(gpa: std.mem.Allocator, opts: Options) !db_mod.Db {
    const parsed = try parseUrl(opts.url);
    var token_owned: ?[]u8 = null;
    if (opts.auth_token) |t| {
        token_owned = try gpa.dupe(u8, t);
    } else if (parsed.embedded_token) |t| {
        token_owned = try gpa.dupe(u8, t);
    }

    const self = try gpa.create(Backend);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .base_url = try std.fmt.allocPrint(gpa, "{s}://{s}", .{ parsed.scheme, parsed.host }),
        .auth_header = if (token_owned) |t|
            try std.fmt.allocPrint(gpa, "Bearer {s}", .{t})
        else
            try gpa.dupe(u8, ""),
        .auth_token = token_owned,
        .baton = null,
    };
    return .{ .ptr = self, .vt = &vtable };
}

const ParsedUrl = struct {
    /// "http" or "https". `libsql://` is treated as `https://`.
    scheme: []const u8,
    host: []const u8,
    embedded_token: ?[]const u8,
};

fn parseUrl(url: []const u8) TursoError!ParsedUrl {
    var rest = url;
    var scheme: []const u8 = "https";
    if (std.mem.startsWith(u8, rest, "libsql://")) {
        rest = rest[9..];
    } else if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
        scheme = "http";
    } else return TursoError.InvalidUrl;

    var host = rest;
    var embedded_token: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        host = rest[0..q];
        var it = std.mem.splitScalar(u8, rest[q + 1 ..], '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const k = kv[0..eq];
            const v = kv[eq + 1 ..];
            if (std.mem.eql(u8, k, "authToken") or std.mem.eql(u8, k, "auth_token")) {
                embedded_token = v;
            }
        }
    }
    // Strip a path segment if present (we always POST to /v3/pipeline).
    if (std.mem.indexOfScalar(u8, host, '/')) |s| host = host[0..s];
    if (host.len == 0) return TursoError.InvalidUrl;
    return .{ .scheme = scheme, .host = host, .embedded_token = embedded_token };
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    base_url: []u8,
    auth_header: []u8, // "Bearer <jwt>" or empty
    auth_token: ?[]u8,
    /// Hrana stream token, returned by the server on the first request and
    /// echoed back on subsequent ones to keep BEGIN/COMMIT on the same logical
    /// session. `null` means "open a fresh stream".
    baton: ?[]u8,
};

const vtable: db_mod.VTable = .{
    .prepare = prepareBackend,
    .exec = execBackend,
    .close = closeBackend,
};

fn closeBackend(ptr: *anyopaque) void {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    self.gpa.free(self.base_url);
    self.gpa.free(self.auth_header);
    if (self.auth_token) |t| self.gpa.free(t);
    if (self.baton) |b| self.gpa.free(b);
    self.gpa.destroy(self);
}

// === exec: one-shot SQL, no rows captured ===
fn execBackend(ptr: *anyopaque, sql: []const u8) anyerror!void {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body_buf: std.ArrayList(u8) = .empty;
    try buildPipeline(arena, &body_buf, self.baton, &[_]Request{
        .{ .kind = .execute, .sql = sql, .args = &.{}, .want_rows = false },
        .{ .kind = .close, .sql = "", .args = &.{}, .want_rows = false },
    });
    var resp_baton: ?[]u8 = null;
    _ = try postPipeline(self, arena, body_buf.items, &resp_baton, null);
    if (resp_baton) |new_baton| {
        if (self.baton) |old| self.gpa.free(old);
        self.baton = new_baton;
    }
}

// === prepare: deferred — args + sql captured locally, sent on first step ===
fn prepareBackend(ptr: *anyopaque, sql: []const u8) anyerror!db_mod.Stmt {
    const self: *Backend = @ptrCast(@alignCast(ptr));
    const s = try self.gpa.create(StmtBackend);
    errdefer self.gpa.destroy(s);
    s.* = .{
        .backend = self,
        .gpa = self.gpa,
        .sql = try self.gpa.dupe(u8, sql),
        .args = .empty,
        .rows = .empty,
        .row_arena = std.heap.ArenaAllocator.init(self.gpa),
        .next_row = 0,
        .executed = false,
    };
    return .{ .ptr = s, .vt = &stmt_vtable };
}

const StmtBackend = struct {
    backend: *Backend,
    gpa: std.mem.Allocator,
    sql: []u8,
    args: std.ArrayList(db_mod.Value),
    /// Hydrated on first step(). Each row is `[]Value`.
    rows: std.ArrayList([]db_mod.Value),
    /// Owns all []const u8 borrowed by `rows`.
    row_arena: std.heap.ArenaAllocator,
    next_row: usize,
    executed: bool,
};

fn bindStmt(ptr: *anyopaque, idx: usize, v: db_mod.Value) anyerror!void {
    const s: *StmtBackend = @ptrCast(@alignCast(ptr));
    // Hrana uses 0-based positional args; idx is 1-based by convention.
    if (idx == 0) return TursoError.InvalidResponse;
    while (s.args.items.len < idx) try s.args.append(s.gpa, .{ .null_value = {} });
    s.args.items[idx - 1] = v;
}

fn stepStmt(ptr: *anyopaque) anyerror!db_mod.StepResult {
    const s: *StmtBackend = @ptrCast(@alignCast(ptr));
    if (!s.executed) {
        try executeOnce(s);
        s.executed = true;
    }
    if (s.next_row >= s.rows.items.len) return .done;
    s.next_row += 1;
    return .row;
}

fn columnIntFn(ptr: *anyopaque, idx: usize) anyerror!i64 {
    const s: *StmtBackend = @ptrCast(@alignCast(ptr));
    const row = currentRow(s) orelse return TursoError.InvalidResponse;
    if (idx >= row.len) return TursoError.InvalidResponse;
    return switch (row[idx]) {
        .int => |v| v,
        .float => |v| @intFromFloat(v),
        .null_value => 0,
        .text => |t| std.fmt.parseInt(i64, t, 10) catch 0,
        else => TursoError.UnsupportedColumnType,
    };
}

fn columnFloatFn(ptr: *anyopaque, idx: usize) anyerror!f64 {
    const s: *StmtBackend = @ptrCast(@alignCast(ptr));
    const row = currentRow(s) orelse return TursoError.InvalidResponse;
    if (idx >= row.len) return TursoError.InvalidResponse;
    return switch (row[idx]) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .null_value => 0,
        else => TursoError.UnsupportedColumnType,
    };
}

fn columnTextFn(ptr: *anyopaque, idx: usize) anyerror![]const u8 {
    const s: *StmtBackend = @ptrCast(@alignCast(ptr));
    const row = currentRow(s) orelse return TursoError.InvalidResponse;
    if (idx >= row.len) return TursoError.InvalidResponse;
    return switch (row[idx]) {
        .text => |t| t,
        .blob => |b| b,
        .null_value => "",
        else => TursoError.UnsupportedColumnType,
    };
}

fn columnBlobFn(ptr: *anyopaque, idx: usize) anyerror![]const u8 {
    return columnTextFn(ptr, idx);
}

fn columnCountFn(ptr: *anyopaque) usize {
    const s: *StmtBackend = @ptrCast(@alignCast(ptr));
    if (s.rows.items.len == 0) return 0;
    return s.rows.items[0].len;
}

fn resetStmt(ptr: *anyopaque) anyerror!void {
    const s: *StmtBackend = @ptrCast(@alignCast(ptr));
    s.next_row = 0;
}

fn deinitStmt(ptr: *anyopaque) void {
    const s: *StmtBackend = @ptrCast(@alignCast(ptr));
    s.args.deinit(s.gpa);
    s.rows.deinit(s.gpa);
    s.row_arena.deinit();
    s.gpa.free(s.sql);
    s.gpa.destroy(s);
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

fn currentRow(s: *StmtBackend) ?[]db_mod.Value {
    if (s.next_row == 0 or s.next_row > s.rows.items.len) return null;
    return s.rows.items[s.next_row - 1];
}

fn executeOnce(s: *StmtBackend) !void {
    var req_arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer req_arena_state.deinit();
    const req_arena = req_arena_state.allocator();

    var body_buf: std.ArrayList(u8) = .empty;
    try buildPipeline(req_arena, &body_buf, s.backend.baton, &[_]Request{
        .{ .kind = .execute, .sql = s.sql, .args = s.args.items, .want_rows = true },
    });

    // Reuse a fresh per-statement row_arena so the column []const u8 slices
    // live until `Stmt.deinit`.
    var resp_baton: ?[]u8 = null;
    const row_alloc = s.row_arena.allocator();
    try postPipeline(s.backend, req_arena, body_buf.items, &resp_baton, .{
        .target = &s.rows,
        .target_alloc = s.gpa,
        .row_text_alloc = row_alloc,
    });
    if (resp_baton) |new_baton| {
        if (s.backend.baton) |old| s.backend.gpa.free(old);
        s.backend.baton = new_baton;
    }
}

// =========================================================================
// Hrana request encoding
// =========================================================================

const RequestKind = enum { execute, close };

const Request = struct {
    kind: RequestKind,
    sql: []const u8,
    args: []const db_mod.Value,
    want_rows: bool,
};

fn buildPipeline(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    baton: ?[]const u8,
    requests: []const Request,
) !void {
    try out.appendSlice(arena, "{\"baton\":");
    if (baton) |b| {
        try out.append(arena, '"');
        try appendJsonEscaped(arena, out, b);
        try out.append(arena, '"');
    } else {
        try out.appendSlice(arena, "null");
    }
    try out.appendSlice(arena, ",\"requests\":[");
    var first = true;
    for (requests) |r| {
        if (!first) try out.append(arena, ',');
        first = false;
        switch (r.kind) {
            .execute => {
                try out.appendSlice(arena, "{\"type\":\"execute\",\"stmt\":{\"sql\":\"");
                try appendJsonEscaped(arena, out, r.sql);
                try out.appendSlice(arena, "\",\"args\":[");
                var arg_first = true;
                for (r.args) |a| {
                    if (!arg_first) try out.append(arena, ',');
                    arg_first = false;
                    try appendHranaValue(arena, out, a);
                }
                try out.appendSlice(arena, "],\"want_rows\":");
                try out.appendSlice(arena, if (r.want_rows) "true" else "false");
                try out.appendSlice(arena, "}}");
            },
            .close => {
                try out.appendSlice(arena, "{\"type\":\"close\"}");
            },
        }
    }
    try out.appendSlice(arena, "]}");
}

fn appendJsonEscaped(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            0...8, 11, 12, 14...31 => {
                var buf: [8]u8 = undefined;
                const hex = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                try out.appendSlice(arena, hex);
            },
            else => try out.append(arena, c),
        }
    }
}

fn appendHranaValue(arena: std.mem.Allocator, out: *std.ArrayList(u8), v: db_mod.Value) !void {
    switch (v) {
        .null_value => try out.appendSlice(arena, "{\"type\":\"null\"}"),
        .int => |x| {
            try out.appendSlice(arena, "{\"type\":\"integer\",\"value\":\"");
            const s = try std.fmt.allocPrint(arena, "{d}", .{x});
            try out.appendSlice(arena, s);
            try out.appendSlice(arena, "\"}");
        },
        .float => |x| {
            const s = try std.fmt.allocPrint(arena, "{d}", .{x});
            try out.appendSlice(arena, "{\"type\":\"float\",\"value\":");
            try out.appendSlice(arena, s);
            try out.append(arena, '}');
        },
        .text => |t| {
            try out.appendSlice(arena, "{\"type\":\"text\",\"value\":\"");
            try appendJsonEscaped(arena, out, t);
            try out.appendSlice(arena, "\"}");
        },
        .blob => |b| {
            // Hrana uses base64-encoded blob value.
            const enc = std.base64.standard.Encoder;
            const enc_len = enc.calcSize(b.len);
            const buf = try arena.alloc(u8, enc_len);
            _ = enc.encode(buf, b);
            try out.appendSlice(arena, "{\"type\":\"blob\",\"base64\":\"");
            try out.appendSlice(arena, buf);
            try out.appendSlice(arena, "\"}");
        },
    }
}

// =========================================================================
// Hrana response decoding (HTTP + JSON parse)
// =========================================================================

const ExecuteTarget = struct {
    target: *std.ArrayList([]db_mod.Value),
    target_alloc: std.mem.Allocator,
    row_text_alloc: std.mem.Allocator,
};

fn postPipeline(
    backend: *Backend,
    arena: std.mem.Allocator,
    body: []const u8,
    out_baton: *?[]u8,
    execute_target: ?ExecuteTarget,
) !void {
    const url = try std.fmt.allocPrint(arena, "{s}/v3/pipeline", .{backend.base_url});
    var headers: std.ArrayList(http_client.Header) = .empty;
    try headers.append(arena, .{ .name = "content-type", .value = "application/json" });
    if (backend.auth_header.len > 0) {
        try headers.append(arena, .{ .name = "authorization", .value = backend.auth_header });
    }
    const resp = http_client.send(arena, .{
        .method = .POST,
        .url = url,
        .headers = headers.items,
        .body = body,
    }) catch return TursoError.HttpFailed;

    if (resp.status == 401 or resp.status == 403) return TursoError.AuthFailed;
    if (resp.status < 200 or resp.status >= 300) return TursoError.HttpFailed;

    try decodeResponse(arena, resp.body, backend.gpa, out_baton, execute_target);
}

/// Hand-rolled minimal JSON decoder for the pipeline response. We avoid
/// std.json's parseLeaky here because the row payload is a dynamic mix of
/// integer/float/text/blob/null and we need to thread `row_text_alloc` so
/// strings outlive the request arena.
fn decodeResponse(
    arena: std.mem.Allocator,
    bytes: []const u8,
    gpa: std.mem.Allocator,
    out_baton: *?[]u8,
    execute_target: ?ExecuteTarget,
) !void {
    const Parsed = struct {
        baton: ?[]const u8 = null,
        results: []std.json.Value = &.{},
    };
    var parsed = std.json.parseFromSlice(std.json.Value, arena, bytes, .{}) catch return TursoError.InvalidResponse;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return TursoError.InvalidResponse;
    if (root.object.get("baton")) |b| if (b == .string) {
        out_baton.* = try gpa.dupe(u8, b.string);
    };
    const results_v = root.object.get("results") orelse return;
    if (results_v != .array) return TursoError.InvalidResponse;

    for (results_v.array.items) |result_v| {
        if (result_v != .object) continue;
        const result_type = result_v.object.get("type") orelse continue;
        if (result_type != .string) continue;
        if (std.mem.eql(u8, result_type.string, "error")) {
            return TursoError.HranaError;
        }
        if (!std.mem.eql(u8, result_type.string, "ok")) continue;
        const response = result_v.object.get("response") orelse continue;
        if (response != .object) continue;
        const resp_type = response.object.get("type") orelse continue;
        if (resp_type != .string) continue;
        if (!std.mem.eql(u8, resp_type.string, "execute")) continue;

        const result = response.object.get("result") orelse continue;
        if (result != .object) continue;
        if (execute_target) |tgt| {
            try decodeRows(result, tgt);
        }
    }
    _ = Parsed{};
}

fn decodeRows(result_obj: std.json.Value, tgt: ExecuteTarget) !void {
    const rows_v = result_obj.object.get("rows") orelse return;
    if (rows_v != .array) return;
    for (rows_v.array.items) |row_v| {
        if (row_v != .array) continue;
        const row = try tgt.target_alloc.alloc(db_mod.Value, row_v.array.items.len);
        for (row_v.array.items, 0..) |cell, i| {
            row[i] = try decodeCell(cell, tgt.row_text_alloc);
        }
        try tgt.target.append(tgt.target_alloc, row);
    }
}

fn decodeCell(cell: std.json.Value, row_text_alloc: std.mem.Allocator) !db_mod.Value {
    if (cell != .object) return TursoError.InvalidResponse;
    const ty = cell.object.get("type") orelse return TursoError.InvalidResponse;
    if (ty != .string) return TursoError.InvalidResponse;
    const tname = ty.string;
    if (std.mem.eql(u8, tname, "null")) return .{ .null_value = {} };
    if (std.mem.eql(u8, tname, "integer")) {
        const val = cell.object.get("value") orelse return TursoError.InvalidResponse;
        // Hrana sends int as JSON string to avoid 53-bit JS truncation.
        const s = switch (val) {
            .string => |x| x,
            .integer => |x| return .{ .int = x },
            else => return TursoError.InvalidResponse,
        };
        return .{ .int = std.fmt.parseInt(i64, s, 10) catch return TursoError.InvalidResponse };
    }
    if (std.mem.eql(u8, tname, "float")) {
        const val = cell.object.get("value") orelse return TursoError.InvalidResponse;
        return switch (val) {
            .float => |x| .{ .float = x },
            .integer => |x| .{ .float = @floatFromInt(x) },
            .string => |x| .{ .float = std.fmt.parseFloat(f64, x) catch return TursoError.InvalidResponse },
            else => TursoError.InvalidResponse,
        };
    }
    if (std.mem.eql(u8, tname, "text")) {
        const val = cell.object.get("value") orelse return TursoError.InvalidResponse;
        if (val != .string) return TursoError.InvalidResponse;
        const copy = try row_text_alloc.dupe(u8, val.string);
        return .{ .text = copy };
    }
    if (std.mem.eql(u8, tname, "blob")) {
        const val = cell.object.get("base64") orelse return TursoError.InvalidResponse;
        if (val != .string) return TursoError.InvalidResponse;
        const dec = std.base64.standard.Decoder;
        const max_len = dec.calcSizeUpperBound(val.string.len) catch return TursoError.InvalidResponse;
        const buf = try row_text_alloc.alloc(u8, max_len);
        dec.decode(buf, val.string) catch return TursoError.InvalidResponse;
        return .{ .blob = buf };
    }
    return TursoError.UnsupportedColumnType;
}

// =========================================================================
// Tests — Hrana JSON round-trip
// =========================================================================

test "buildPipeline encodes execute + args" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buildPipeline(arena, &buf, null, &[_]Request{.{
        .kind = .execute,
        .sql = "SELECT * FROM t WHERE id = ?",
        .args = &[_]db_mod.Value{.{ .int = 42 }},
        .want_rows = true,
    }});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"baton\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"type\":\"execute\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"type\":\"integer\",\"value\":\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"want_rows\":true") != null);
}

test "buildPipeline JSON-escapes SQL with quotes/newlines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try buildPipeline(arena, &buf, "tok\"with\"quotes", &[_]Request{.{
        .kind = .execute,
        .sql = "SELECT 'a\"b\\c\nd'",
        .args = &.{},
        .want_rows = false,
    }});
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"baton\":\"tok\\\"with\\\"quotes\"") != null);
}

test "parseUrl accepts libsql:// and https:// and extracts authToken" {
    const a = try parseUrl("libsql://my-db-org.turso.io");
    try std.testing.expectEqualStrings("my-db-org.turso.io", a.host);
    try std.testing.expect(a.embedded_token == null);
    const b = try parseUrl("https://host.example.com?authToken=eyJab.c");
    try std.testing.expectEqualStrings("host.example.com", b.host);
    try std.testing.expectEqualStrings("eyJab.c", b.embedded_token.?);
}
