//! Compile-time endpoint contracts and typed request inputs.
const std = @import("std");
const openapi = @import("openapi.zig");

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
