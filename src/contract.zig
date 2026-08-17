//! Compile-time endpoint contracts and typed request inputs.
const std = @import("std");
const openapi = @import("openapi.zig");
const context = @import("context.zig");

/// A route is declared once and can then be registered, inspected, and used
/// by OpenAPI/client generators through the same metadata pointer.
pub fn Endpoint(comptime method: anytype, comptime path: []const u8, comptime handler: anytype, comptime spec: openapi.SpecOpts) type {
    return struct {
        pub const http_method = method;
        pub const route_path = path;
        pub const handle = handler;
        pub const meta = openapi.Spec(spec);

        pub fn register(app: anytype) !void {
            _ = try app.endpoint(http_method, route_path, handle, meta);
        }
    };
}

/// Validate a tuple of Endpoint types at comptime. This is useful for route
/// modules that want duplicate and operation-id failures before App.init.
pub fn validateGraph(comptime endpoints: anytype) void {
    @setEvalBranchQuota(50_000_000);
    inline for (endpoints, 0..) |endpoint, i| {
        validatePath(endpoint.route_path);
        inline for (endpoints, 0..) |before, before_index| {
            if (before_index >= i) continue;
            if (endpoint.http_method == before.http_method and std.mem.eql(u8, endpoint.route_path, before.route_path))
                @compileError("duplicate endpoint in contract graph: " ++ endpoint.route_path);
            if (endpoint.http_method == before.http_method and pathsAmbiguous(endpoint.route_path, before.route_path))
                @compileError("ambiguous endpoint in contract graph: " ++ endpoint.route_path ++ " conflicts with " ++ before.route_path);
            if (endpoint.meta.operation_id.len > 0 and std.mem.eql(u8, endpoint.meta.operation_id, before.meta.operation_id))
                @compileError("duplicate operation_id in contract graph: " ++ endpoint.meta.operation_id);
        }
    }
}

pub fn validateCapabilities(comptime endpoints: anytype, comptime target: @import("capability.zig").Target) void {
    inline for (endpoints) |endpoint| {
        if (@hasDecl(endpoint, "required_capabilities")) {
            @import("capability.zig").requireKinds(
                "route " ++ @tagName(endpoint.http_method) ++ " " ++ endpoint.route_path,
                endpoint.required_capabilities,
                target,
            );
        }
    }
}

fn validatePath(comptime path: []const u8) void {
    if (path.len == 0 or path[0] != '/') @compileError("endpoint path must start with '/': " ++ path);
    if (std.mem.indexOf(u8, path, "//") != null) @compileError("endpoint path contains an empty segment: " ++ path);
    const segments = @import("static_router.zig").parse(path);
    inline for (segments, 0..) |segment, i| {
        if (segment.kind != .literal and segment.text.len == 0)
            @compileError("path parameter must have a name: " ++ path);
        if (segment.kind == .wildcard and i + 1 != segments.len)
            @compileError("wildcard must be the final path segment: " ++ path);
        if (segment.kind != .literal) inline for (segments[0..i]) |prior| {
            if (prior.kind != .literal and std.mem.eql(u8, prior.text, segment.text))
                @compileError("duplicate path parameter `" ++ segment.text ++ "` in " ++ path);
        };
    }
}

fn pathsAmbiguous(comptime a: []const u8, comptime b: []const u8) bool {
    const lhs = @import("static_router.zig").parse(a);
    const rhs = @import("static_router.zig").parse(b);
    comptime var i: usize = 0;
    inline while (i < lhs.len and i < rhs.len) : (i += 1) {
        if (lhs[i].kind == .wildcard or rhs[i].kind == .wildcard) return true;
        if (lhs[i].kind == .literal and rhs[i].kind == .literal and
            !std.mem.eql(u8, lhs[i].text, rhs[i].text)) return false;
    }
    if (i < lhs.len and lhs[i].kind == .wildcard) return true;
    if (i < rhs.len and rhs[i].kind == .wildcard) return true;
    return lhs.len == rhs.len;
}

pub const Source = enum { path, query, header, cookie, json };

/// Marker used by tooling to describe where a handler input originates.
pub fn Input(comptime T: type, comptime source: Source, comptime name: []const u8) type {
    return struct {
        pub const Value = T;
        pub const input_source = source;
        pub const input_name = name;
        value: T,

        pub fn read(c: anytype) !@This() {
            return .{ .value = switch (source) {
                .path => try c.req.paramAs(T, name),
                .query => try parseMaybeScalar(T, c.req.query(name)),
                .header => try parseMaybeScalar(T, c.req.header(name)),
                .cookie => try parseMaybeScalar(T, c.req.cookie(name)),
                .json => try c.req.json(T),
            } };
        }
    };
}

pub fn Path(comptime T: type, comptime name: []const u8) type {
    return Input(T, .path, name);
}
pub fn Query(comptime T: type, comptime name: []const u8) type {
    return Input(T, .query, name);
}
pub fn Header(comptime T: type, comptime name: []const u8) type {
    return Input(T, .header, name);
}
pub fn Cookie(comptime T: type, comptime name: []const u8) type {
    return Input(T, .cookie, name);
}
pub fn Json(comptime T: type) type {
    return Input(T, .json, "body");
}

/// Adapt a typed input struct to Akamata's zero-allocation handler ABI.
/// Every field must be an Input wrapper such as Path, Query, Header, Cookie,
/// or Json. Extraction and conversion are generated at comptime.
pub fn Bound(
    comptime State: type,
    comptime Inputs: type,
    comptime handler: *const fn (*context.Context(State), Inputs) anyerror!void,
) type {
    return BoundForPath(State, null, Inputs, handler);
}

/// Like `Bound`, but validates input markers against a route path. Endpoint
/// declarations use this to reject missing/duplicate path parameters and
/// multiple JSON bodies before any application code runs.
pub fn BoundForPath(
    comptime State: type,
    comptime path: ?[]const u8,
    comptime Inputs: type,
    comptime handler: *const fn (*context.Context(State), Inputs) anyerror!void,
) type {
    const info = @typeInfo(Inputs);
    if (info != .@"struct") @compileError("contract.Bound Inputs must be a struct");
    comptime var json_count: usize = 0;
    inline for (info.@"struct".fields, 0..) |field, i| {
        if (!@hasDecl(field.type, "input_source") or !@hasDecl(field.type, "read"))
            @compileError("contract.Bound field `" ++ field.name ++ "` must use Path, Query, Header, Cookie, or Json");
        if (field.type.input_source == .json) json_count += 1;
        inline for (info.@"struct".fields[0..i]) |prior| {
            if (prior.type.input_source == field.type.input_source and
                std.mem.eql(u8, prior.type.input_name, field.type.input_name))
                @compileError("duplicate typed input `" ++ field.type.input_name ++ "`");
        }
        if (path) |route_path| if (field.type.input_source == .path) {
            comptime var found = false;
            inline for (@import("static_router.zig").parse(route_path)) |segment| {
                if (segment.kind != .literal and std.mem.eql(u8, segment.text, field.type.input_name)) {
                    found = true;
                }
            }
            if (!found) @compileError("Path(\"" ++ field.type.input_name ++ "\") is not present in route " ++ route_path);
        };
    }
    if (json_count > 1) @compileError("a typed request contract may contain only one JSON body");
    return struct {
        pub fn handle(c: *context.Context(State)) anyerror!void {
            var inputs: Inputs = undefined;
            inline for (@typeInfo(Inputs).@"struct".fields) |field| {
                @field(inputs, field.name) = try field.type.read(c);
            }
            return handler(c, inputs);
        }
    };
}

/// Validate that every member of a handler's typed error set has an HTTP
/// mapping. `mapping` is an anonymous struct such as
/// `.{ .NotFound = .not_found, .Invalid = .bad_request }`.
pub fn validateErrorMap(comptime handler: anytype, comptime mapping: anytype) void {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";
    const return_type = fn_info.return_type orelse @compileError("handler must have a return type");
    const return_info = @typeInfo(return_type);
    if (return_info != .error_union) @compileError("typed error mapping requires an error-union handler return type");
    const errors = @typeInfo(return_info.error_union.error_set);
    if (errors.error_set == null) @compileError("typed error mapping does not accept anyerror");
    inline for (errors.error_set.?) |err| {
        if (!@hasField(@TypeOf(mapping), err.name))
            @compileError("missing HTTP mapping for handler error " ++ err.name);
    }
    inline for (@typeInfo(@TypeOf(mapping)).@"struct".fields) |field| {
        comptime var exists = false;
        inline for (errors.error_set.?) |err| if (std.mem.eql(u8, field.name, err.name)) {
            exists = true;
        };
        if (!exists) @compileError("HTTP mapping contains error not returned by handler: " ++ field.name);
    }
}

pub const TypedMeta = struct {
    summary: []const u8 = "",
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    operation_id: []const u8 = "",
    success_status: u16 = 200,
};

/// Adapt a typed `(Context, Inputs) ErrorSet!Response` function into the
/// existing Context handler ABI. Its reflected request/response types feed the
/// same OpenAPI metadata used by the runtime API.
pub fn TypedEndpoint(
    comptime State: type,
    comptime method: anytype,
    comptime path: []const u8,
    comptime handler: anytype,
    comptime error_map: anytype,
    comptime details: TypedMeta,
) type {
    const fn_info = @typeInfo(@TypeOf(handler)).@"fn";
    if (fn_info.params.len != 2) @compileError("typed endpoint handler must accept (Context, Inputs)");
    const ExpectedContext = *context.Context(State);
    if (fn_info.params[0].type == null or fn_info.params[0].type.? != ExpectedContext)
        @compileError("typed endpoint first parameter must be *Context(State)");
    const Inputs = fn_info.params[1].type orelse @compileError("typed endpoint Inputs must have a concrete type");
    const return_type = fn_info.return_type orelse @compileError("typed endpoint handler must return an error union");
    const return_info = @typeInfo(return_type);
    if (return_info != .error_union) @compileError("typed endpoint handler must return ErrorSet!Response");
    const Response = return_info.error_union.payload;
    validateErrorMap(handler, error_map);
    _ = BoundForPath(State, path, Inputs, struct {
        fn validationOnly(_: *context.Context(State), _: Inputs) anyerror!void {}
    }.validationOnly);
    const Request = jsonBodyType(Inputs);
    const endpoint_meta = openapi.Spec(.{
        .request = Request,
        .response = if (Response == void) null else Response,
        .summary = details.summary,
        .description = details.description,
        .tags = details.tags,
        .operation_id = details.operation_id,
        .success_status = details.success_status,
        .additional_responses = errorResponses(error_map),
    });
    return struct {
        pub const http_method = method;
        pub const route_path = path;
        pub const meta = endpoint_meta;
        pub const InputType = Inputs;
        pub const ResponseType = Response;
        pub const ErrorSet = return_info.error_union.error_set;

        pub fn handle(c: *context.Context(State)) anyerror!void {
            var inputs: Inputs = undefined;
            inline for (@typeInfo(Inputs).@"struct".fields) |field| {
                @field(inputs, field.name) = try field.type.read(c);
            }
            const value = handler(c, inputs) catch |err| {
                const code = statusForError(error_map, err);
                c.status(@intFromEnum(code));
                try c.json(.{ .error_kind = @errorName(err) }, @intFromEnum(code));
                return;
            };
            if (Response == void) {
                c.status(details.success_status);
            } else {
                try c.json(value, details.success_status);
            }
        }

        pub fn register(app: anytype) !void {
            _ = try app.endpoint(http_method, route_path, handle, meta);
        }
    };
}

fn jsonBodyType(comptime Inputs: type) ?type {
    comptime var result: ?type = null;
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type.input_source == .json) result = field.type.Value;
    }
    return result;
}

fn errorResponses(comptime mapping: anytype) []const openapi.ResponseDoc {
    comptime var result: []const openapi.ResponseDoc = &.{};
    inline for (@typeInfo(@TypeOf(mapping)).@"struct".fields) |field| {
        const code = @field(mapping, field.name);
        result = result ++ .{openapi.ResponseDoc{ .status = @intFromEnum(code), .description = field.name }};
    }
    return result;
}

fn statusForError(comptime mapping: anytype, err: anyerror) @import("http/status.zig").Code {
    inline for (@typeInfo(@TypeOf(mapping)).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, @errorName(err))) return @field(mapping, field.name);
    }
    unreachable; // validateErrorMap proves exhaustiveness for the typed handler.
}

fn parseScalar(comptime T: type, raw: []const u8) !T {
    if (T == []const u8) return raw;
    if (T == bool) {
        if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
        if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
        return error.InvalidInput;
    }
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, raw, 10),
        .float => std.fmt.parseFloat(T, raw),
        else => @compileError("typed request inputs support strings, booleans, integers, and floats"),
    };
}

fn parseMaybeScalar(comptime T: type, raw: ?[]const u8) !T {
    if (@typeInfo(T) == .optional) {
        const value = raw orelse return null;
        return try parseScalar(@typeInfo(T).optional.child, value);
    }
    return parseScalar(T, raw orelse return error.MissingInput);
}

test "typed input metadata is available at comptime" {
    const Id = Path(u64, "id");
    try std.testing.expectEqual(Source.path, Id.input_source);
    try std.testing.expectEqualStrings("id", Id.input_name);
}

test "Bound exposes the standard context handler shape" {
    const State = struct {};
    const Inputs = struct { id: Path(u64, "id") };
    const example = struct {
        fn call(_: *context.Context(State), _: Inputs) !void {}
    }.call;
    const Adapter = Bound(State, Inputs, example);
    try std.testing.expect(@typeInfo(@TypeOf(Adapter.handle)) == .@"fn");
}

test "validateGraph accepts a unique endpoint tuple" {
    const State = struct {};
    const handler = struct {
        fn call(_: *context.Context(State)) !void {}
    }.call;
    const One = Endpoint(.GET, "/one", handler, .{ .operation_id = "one" });
    const Two = Endpoint(.POST, "/two", handler, .{ .operation_id = "two" });
    comptime validateGraph(.{ One, Two });
}
