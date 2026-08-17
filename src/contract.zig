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
    const fields = @typeInfo(@TypeOf(endpoints)).@"struct".fields;
    inline for (fields, 0..) |field, i| {
        const endpoint = @field(endpoints, field.name);
        if (endpoint.route_path.len == 0 or endpoint.route_path[0] != '/')
            @compileError("endpoint path must start with '/': " ++ endpoint.route_path);
        inline for (fields[0..i]) |before_field| {
            const before = @field(endpoints, before_field.name);
            if (endpoint.http_method == before.http_method and std.mem.eql(u8, endpoint.route_path, before.route_path))
                @compileError("duplicate endpoint in contract graph: " ++ endpoint.route_path);
            if (endpoint.meta.operation_id.len > 0 and std.mem.eql(u8, endpoint.meta.operation_id, before.meta.operation_id))
                @compileError("duplicate operation_id in contract graph: " ++ endpoint.meta.operation_id);
        }
    }
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
                .query => try parseScalar(T, c.req.query(name) orelse return error.MissingInput),
                .header => try parseScalar(T, c.req.header(name) orelse return error.MissingInput),
                .cookie => try parseScalar(T, c.req.cookie(name) orelse return error.MissingInput),
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
    const info = @typeInfo(Inputs);
    if (info != .@"struct") @compileError("contract.Bound Inputs must be a struct");
    inline for (info.@"struct".fields) |field| {
        if (!@hasDecl(field.type, "input_source") or !@hasDecl(field.type, "read"))
            @compileError("contract.Bound field `" ++ field.name ++ "` must use Path, Query, Header, Cookie, or Json");
    }
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
