//! OpenAPI 3.1 spec generation.
//!
//! Routes registered via `app.endpoint(...)` carry typed request/response
//! information; `generate(app, info)` walks them and emits an OpenAPI JSON
//! document. Routes registered via the bare `app.get/post/...` helpers are
//! treated as undocumented and skipped.
//!
//! The generator only depends on Zig stdlib (std.json, comptime reflection).
//! No runtime cost is paid by apps that don't call `generate`.

const std = @import("std");

/// Per-route metadata stamped at registration time. Stored once in static
/// memory (the value lives in `.rodata`) and referenced from `Route.meta`.
pub const EndpointMeta = struct {
    summary: []const u8 = "",
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    /// Render `request` and `response` into the OpenAPI components.schemas
    /// table and return a `$ref` string. Generated per-T at comptime.
    schema_fn: *const fn (gpa: std.mem.Allocator, ctx: *SpecBuilder) anyerror!Refs,
    /// Emit the query-parameter object list (`{"name":"q","in":"query",...}`
    /// fragments separated by commas — no leading or trailing comma) to
    /// `w`. Returns the number of params emitted. Comptime-bound to the
    /// query struct shape. `null` when the endpoint declares no `.query`.
    query_params_fn: ?*const fn (w: *std.Io.Writer) anyerror!usize = null,
    /// Same shape, used by the TS client generator to type the `query`
    /// argument. Emits `key?: type;` lines.
    query_ts_fields_fn: ?*const fn (w: *std.Io.Writer) anyerror!void = null,

    pub const Refs = struct {
        /// `null` means: this endpoint has no body. e.g. GET requests.
        request: ?[]const u8 = null,
        response: ?[]const u8 = null,
    };
};

/// Top-level metadata stamped at spec-build time.
pub const Info = struct {
    title: []const u8 = "Akamata API",
    version: []const u8 = "0.0.0",
    description: []const u8 = "",
};

/// Mutable state passed through schema generators. Lets each generator
/// register a JSON Schema object under `components.schemas` exactly once
/// per type name.
pub const SpecBuilder = struct {
    arena: std.mem.Allocator,
    /// "User" -> JSON Schema object as already-stringified JSON text. We
    /// keep the text rather than a value tree because std.json doesn't
    /// have a stable typed Value graph in 0.16, and re-emitting from
    /// strings is simpler.
    schemas: std.StringHashMap([]const u8),

    pub fn init(gpa: std.mem.Allocator) SpecBuilder {
        return .{
            .arena = gpa,
            .schemas = .init(gpa),
        };
    }

    pub fn registerSchema(self: *SpecBuilder, comptime T: type) anyerror![]const u8 {
        const name = comptime shortTypeName(T);
        if (self.schemas.contains(name)) {
            return std.fmt.allocPrint(self.arena, "#/components/schemas/{s}", .{name});
        }
        var buf: std.ArrayList(u8) = .empty;
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.arena, &buf);
        defer buf = aw.toArrayList();
        try writeTypeSchema(T, self, &aw.writer);
        try self.schemas.put(name, aw.writer.buffered());
        return std.fmt.allocPrint(self.arena, "#/components/schemas/{s}", .{name});
    }
};

/// Build the EndpointMeta.schema_fn for a (request, response) pair at
/// comptime. Use as: `Spec(.{ .request = MyIn, .response = MyOut })`.
pub fn Spec(comptime opts: SpecOpts) *const EndpointMeta {
    const closure = struct {
        fn schemaFn(gpa: std.mem.Allocator, ctx: *SpecBuilder) anyerror!EndpointMeta.Refs {
            _ = gpa;
            var refs: EndpointMeta.Refs = .{};
            if (opts.request) |Req| refs.request = try ctx.registerSchema(Req);
            if (opts.response) |Res| refs.response = try ctx.registerSchema(Res);
            return refs;
        }
        fn queryParamsFn(w: *std.Io.Writer) anyerror!usize {
            const Q = opts.query orelse return 0;
            const info = @typeInfo(Q);
            if (info != .@"struct") return 0;
            var count: usize = 0;
            inline for (info.@"struct".fields) |f| {
                if (count > 0) try w.writeAll(",");
                count += 1;
                const required = @typeInfo(f.type) != .optional and f.defaultValue() == null;
                try w.writeAll("{\"name\":");
                try writeJsonString(w, f.name);
                try w.print(",\"in\":\"query\",\"required\":{s},\"schema\":", .{
                    if (required) "true" else "false",
                });
                try writeQueryFieldSchema(unwrapOptional(f.type), w);
                try w.writeAll("}");
            }
            return count;
        }
        fn queryTsFieldsFn(w: *std.Io.Writer) anyerror!void {
            const Q = opts.query orelse return;
            const info = @typeInfo(Q);
            if (info != .@"struct") return;
            inline for (info.@"struct".fields) |f| {
                // Every query param is rendered as optional in TS — the
                // user can choose to omit it. Required-ness is enforced
                // by the OpenAPI spec, not the TS type, since the wire
                // format already carries the constraint.
                try w.print("    {s}?: ", .{f.name});
                try writeTsScalar(unwrapOptional(f.type), w);
                try w.writeAll(";\n");
            }
        }
    };
    const has_query = opts.query != null;
    const meta: EndpointMeta = .{
        .summary = opts.summary,
        .description = opts.description,
        .tags = opts.tags,
        .schema_fn = closure.schemaFn,
        .query_params_fn = if (has_query) closure.queryParamsFn else null,
        .query_ts_fields_fn = if (has_query) closure.queryTsFieldsFn else null,
    };
    // Need to return a pointer to const data with static lifetime: use a
    // comptime-promoted block that produces a const decl.
    const Static = struct {
        const value: EndpointMeta = meta;
    };
    return &Static.value;
}

pub const SpecOpts = struct {
    request: ?type = null,
    response: ?type = null,
    /// Struct describing the supported query-string keys. Field names map
    /// 1:1 to query parameter names, field types decide JSON-Schema type,
    /// and optional fields are marked `required: false` in the spec.
    query: ?type = null,
    summary: []const u8 = "",
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
};

/// Write the OpenAPI 3.1 document for `app` to stdout. Convenience wrapper
/// for the common pattern of exposing a `--openapi` flag in an app binary.
pub fn printToStdout(comptime AppT: type, app: *AppT, gpa: std.mem.Allocator, info: Info) !void {
    const spec = try generate(AppT, app, gpa, info);
    defer gpa.free(spec);
    var stdout_buf: [4096]u8 = undefined;
    var sw = std.fs.File.stdout().writer(&stdout_buf);
    try sw.interface.writeAll(spec);
    try sw.interface.writeAll("\n");
    try sw.interface.flush();
}

/// Walk every route on `app` that has metadata attached and emit an
/// OpenAPI 3.1 document as a JSON string (allocated in `gpa`).
pub fn generate(comptime AppT: type, app: *AppT, gpa: std.mem.Allocator, info: Info) ![]u8 {
    // All intermediate allocations (paths, refs, schemas) flow through a
    // single arena; only the final returned JSON string lives in `gpa`.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder: SpecBuilder = .init(arena);

    var paths: std.StringHashMap(std.ArrayList(OperationEntry)) = .init(arena);

    const route_views = try app.routeViews(arena);
    for (route_views) |r| {
        if (r.kind != .http) continue;
        const meta = r.meta orelse continue;
        const refs = try meta.schema_fn(arena, &builder);
        const op_path = try toOpenApiPath(arena, r.path);
        const gop = try paths.getOrPut(op_path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, .{
            .method = r.method,
            .meta = meta,
            .refs = refs,
            .raw_path = r.path,
        });
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("{\"openapi\":\"3.1.0\",\"info\":{\"title\":");
    try writeJsonString(w, info.title);
    try w.writeAll(",\"version\":");
    try writeJsonString(w, info.version);
    if (info.description.len > 0) {
        try w.writeAll(",\"description\":");
        try writeJsonString(w, info.description);
    }
    try w.writeAll("},\"paths\":{");

    var path_it = paths.iterator();
    var first_path = true;
    while (path_it.next()) |entry| {
        if (!first_path) try w.writeAll(",");
        first_path = false;
        try writeJsonString(w, entry.key_ptr.*);
        try w.writeAll(":{");
        var first_op = true;
        for (entry.value_ptr.items) |op| {
            if (!first_op) try w.writeAll(",");
            first_op = false;
            try writeOperation(w, op);
        }
        try w.writeAll("}");
    }
    try w.writeAll("},\"components\":{\"schemas\":{");
    var sch_it = builder.schemas.iterator();
    var first_sch = true;
    while (sch_it.next()) |entry| {
        if (!first_sch) try w.writeAll(",");
        first_sch = false;
        try writeJsonString(w, entry.key_ptr.*);
        try w.writeAll(":");
        try w.writeAll(entry.value_ptr.*);
    }
    try w.writeAll("}}}");

    return gpa.dupe(u8, aw.writer.buffered());
}

const OperationEntry = struct {
    method: @import("http/request.zig").Method,
    meta: *const EndpointMeta,
    refs: EndpointMeta.Refs,
    raw_path: []const u8,
};

fn writeOperation(w: *std.Io.Writer, op: OperationEntry) !void {
    try writeJsonString(w, lowerMethod(op.method));
    try w.writeAll(":{");
    var first = true;
    if (op.meta.summary.len > 0) {
        try writeKv(w, &first, "summary", op.meta.summary);
    }
    if (op.meta.description.len > 0) {
        try writeKv(w, &first, "description", op.meta.description);
    }
    if (op.meta.tags.len > 0) {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\"tags\":[");
        for (op.meta.tags, 0..) |t, i| {
            if (i > 0) try w.writeAll(",");
            try writeJsonString(w, t);
        }
        try w.writeAll("]");
    }

    // Path parameters from `:id` segments + query parameters from
    // `Spec(.{ .query = T })`. Both go in the same OpenAPI
    // `parameters` array, distinguished by `in: path` / `in: query`.
    var path_param_count: usize = 0;
    {
        var seg_it = std.mem.splitScalar(u8, op.raw_path, '/');
        while (seg_it.next()) |seg| {
            if (seg.len > 0 and seg[0] == ':') path_param_count += 1;
        }
    }
    const has_query_fn = op.meta.query_params_fn != null;
    if (path_param_count > 0 or has_query_fn) {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\"parameters\":[");
        var first_p = true;
        // Path params first.
        var seg_it = std.mem.splitScalar(u8, op.raw_path, '/');
        while (seg_it.next()) |seg| {
            if (seg.len == 0 or seg[0] != ':') continue;
            if (!first_p) try w.writeAll(",");
            first_p = false;
            try w.writeAll("{\"name\":");
            try writeJsonString(w, seg[1..]);
            try w.writeAll(",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"string\"}}");
        }
        // Then query params.
        if (op.meta.query_params_fn) |qf| {
            if (!first_p) try w.writeAll(",");
            _ = try qf(w);
        }
        try w.writeAll("]");
    }

    if (op.refs.request) |req_ref| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":");
        try writeJsonString(w, req_ref);
        try w.writeAll("}}}}");
    }

    if (!first) try w.writeAll(",");
    first = false;
    try w.writeAll("\"responses\":{\"200\":{\"description\":\"OK\"");
    if (op.refs.response) |res_ref| {
        try w.writeAll(",\"content\":{\"application/json\":{\"schema\":{\"$ref\":");
        try writeJsonString(w, res_ref);
        try w.writeAll("}}}");
    }
    try w.writeAll("}}");

    try w.writeAll("}");
}

fn writeKv(w: *std.Io.Writer, first: *bool, key: []const u8, val: []const u8) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    try writeJsonString(w, key);
    try w.writeAll(":");
    try writeJsonString(w, val);
}

fn lowerMethod(m: @import("http/request.zig").Method) []const u8 {
    return switch (m) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .DELETE => "delete",
        .PATCH => "patch",
        .OPTIONS => "options",
        .HEAD => "head",
    };
}

/// Translate Akamata's `:param` / `*rest` syntax into OpenAPI's `{param}`.
fn toOpenApiPath(gpa: std.mem.Allocator, p: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < p.len) {
        const c = p[i];
        if (c == ':') {
            // Read name until next '/' or end.
            const start = i + 1;
            var end = start;
            while (end < p.len and p[end] != '/') : (end += 1) {}
            try out.append(gpa, '{');
            try out.appendSlice(gpa, p[start..end]);
            try out.append(gpa, '}');
            i = end;
        } else if (c == '*') {
            const start = i + 1;
            var end = start;
            while (end < p.len and p[end] != '/') : (end += 1) {}
            try out.append(gpa, '{');
            try out.appendSlice(gpa, p[start..end]);
            try out.append(gpa, '}');
            i = end;
        } else {
            try out.append(gpa, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Render a JSON Schema fragment for `T`. Recurses through nested structs
/// and registers them in the same `SpecBuilder` (so they get their own
/// `#/components/schemas/...` entry).
fn writeTypeSchema(comptime T: type, ctx: *SpecBuilder, w: *std.Io.Writer) anyerror!void {
    const info = @typeInfo(T);
    switch (info) {
        .bool => try w.writeAll("{\"type\":\"boolean\"}"),
        .int => |i| {
            const fmt: []const u8 = if (i.bits >= 32) "int64" else "int32";
            try w.print("{{\"type\":\"integer\",\"format\":\"{s}\"}}", .{fmt});
        },
        .float => |f| {
            const fmt: []const u8 = if (f.bits >= 64) "double" else "float";
            try w.print("{{\"type\":\"number\",\"format\":\"{s}\"}}", .{fmt});
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try w.writeAll("{\"type\":\"string\"}");
            } else if (p.size == .slice) {
                try w.writeAll("{\"type\":\"array\",\"items\":");
                try writeTypeSchema(p.child, ctx, w);
                try w.writeAll("}");
            } else {
                try writeTypeSchema(p.child, ctx, w);
            }
        },
        .array => |a| {
            if (a.child == u8) {
                try w.writeAll("{\"type\":\"string\"}");
            } else {
                try w.writeAll("{\"type\":\"array\",\"items\":");
                try writeTypeSchema(a.child, ctx, w);
                try w.writeAll("}");
            }
        },
        .optional => |o| {
            // OpenAPI 3.1: nullable is expressed as a type union.
            try w.writeAll("{\"oneOf\":[{\"type\":\"null\"},");
            try writeTypeSchema(o.child, ctx, w);
            try w.writeAll("]}");
        },
        .@"struct" => |s| {
            try w.writeAll("{\"type\":\"object\",\"properties\":{");
            var first = true;
            inline for (s.fields) |f| {
                if (!first) try w.writeAll(",");
                first = false;
                try writeJsonString(w, f.name);
                try w.writeAll(":");
                try writeTypeSchema(f.type, ctx, w);
            }
            try w.writeAll("},\"required\":[");
            var first_req = true;
            inline for (s.fields) |f| {
                const is_optional = @typeInfo(f.type) == .optional;
                if (is_optional or f.default_value_ptr != null) continue;
                if (!first_req) try w.writeAll(",");
                first_req = false;
                try writeJsonString(w, f.name);
            }
            try w.writeAll("]}");
        },
        .@"enum" => |e| {
            try w.writeAll("{\"type\":\"string\",\"enum\":[");
            inline for (e.fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(",");
                try writeJsonString(w, f.name);
            }
            try w.writeAll("]}");
        },
        else => try w.writeAll("{}"),
    }
}

fn unwrapOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Emit an OpenAPI scalar schema for the kinds of types you'd find in a
/// query-string struct. Strings / numbers / bools / enums only — nested
/// objects don't make sense in querystrings.
fn writeQueryFieldSchema(comptime T: type, w: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .bool => try w.writeAll("{\"type\":\"boolean\"}"),
        .int => try w.writeAll("{\"type\":\"integer\"}"),
        .float => try w.writeAll("{\"type\":\"number\"}"),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try w.writeAll("{\"type\":\"string\"}");
            } else {
                try w.writeAll("{\"type\":\"string\"}");
            }
        },
        .@"enum" => |e| {
            try w.writeAll("{\"type\":\"string\",\"enum\":[");
            inline for (e.fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(",");
                try writeJsonString(w, f.name);
            }
            try w.writeAll("]}");
        },
        else => try w.writeAll("{\"type\":\"string\"}"),
    }
}

/// Emit the TS scalar type for a query-string field. Mirrors
/// writeQueryFieldSchema but on the JS/TS side.
pub fn writeTsScalar(comptime T: type, w: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .bool => try w.writeAll("boolean"),
        .int, .float => try w.writeAll("number"),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try w.writeAll("string");
            } else try w.writeAll("string");
        },
        else => try w.writeAll("string"),
    }
}

fn shortTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // Pick the segment after the last dot, e.g. "examples.user.User" -> "User".
    var last_dot: usize = 0;
    var i: usize = 0;
    while (i < full.len) : (i += 1) {
        if (full[i] == '.') last_dot = i + 1;
    }
    return full[last_dot..];
}

// ===== tests =====

test "writeTypeSchema renders primitives and structs" {
    const T = struct { id: i64, name: []const u8, active: bool = true };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx: SpecBuilder = .init(arena.allocator());
    defer ctx.schemas.deinit();
    var out: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena.allocator(), &out);
    defer out = aw.toArrayList();
    try writeTypeSchema(T, &ctx, &aw.writer);
    const got = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\":{\"type\":\"integer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"name\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"active\":{\"type\":\"boolean\"}") != null);
    // active has a default → not required; id and name are required.
    try std.testing.expect(std.mem.indexOf(u8, got, "\"required\":[\"id\",\"name\"]") != null);
}

test "toOpenApiPath rewrites :param to {param}" {
    const got = try toOpenApiPath(std.testing.allocator, "/users/:id/posts/:post_id");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/users/{id}/posts/{post_id}", got);
}
