//! Compile-time route graph and allocation-free matcher.
//!
//! Endpoint types are the source of truth. The graph pre-parses their paths at
//! comptime and can either register them with `App` for compatibility or match
//! them directly without runtime route storage or pattern parsing.
const std = @import("std");
const status = @import("http/status.zig");

pub const SegmentKind = enum { literal, parameter, wildcard };
pub const Segment = struct { kind: SegmentKind, text: []const u8 };
pub const Params = struct {
    names: [16][]const u8 = undefined,
    values: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const Params, name: []const u8) ?[]const u8 {
        for (self.names[0..self.len], self.values[0..self.len]) |n, value|
            if (std.mem.eql(u8, n, name)) return value;
        return null;
    }
};

pub fn parse(comptime path: []const u8) []const Segment {
    comptime var result: []const Segment = &.{};
    comptime var begin: usize = if (path.len > 0 and path[0] == '/') 1 else 0;
    comptime var i = begin;
    inline while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            if (i > begin) {
                const part = path[begin..i];
                const segment: Segment = if (part[0] == ':')
                    .{ .kind = .parameter, .text = part[1..] }
                else if (part[0] == '*')
                    .{ .kind = .wildcard, .text = part[1..] }
                else
                    .{ .kind = .literal, .text = part };
                result = result ++ .{segment};
            }
            begin = i + 1;
        }
    }
    return result;
}

pub fn Graph(comptime endpoints: anytype) type {
    return struct {
        pub const route_count = endpoints.len;
        /// Fully unrolled matching is intentionally bounded: beyond this
        /// point instruction-cache pressure and code size outweigh dispatch
        /// savings on representative native/Workers targets.
        pub const specialization_threshold = 32;
        pub const prefer_specialized_matcher = endpoints.len <= specialization_threshold;

        pub fn validate() void {
            @import("contract.zig").validateGraph(endpoints);
        }

        pub fn validateTarget(comptime target: @import("capability.zig").Target) void {
            validate();
            @import("contract.zig").validateCapabilities(endpoints, target);
        }

        pub fn register(app: anytype) !void {
            comptime validate();
            inline for (endpoints) |E| try E.register(app);
        }

        pub const Match = struct {
            index: usize,
            params: Params,
        };

        const Pattern = struct { method: status.Method, segments: []const Segment };
        fn makePatterns() [endpoints.len]Pattern {
            @setEvalBranchQuota(10_000_000);
            var result: [endpoints.len]Pattern = undefined;
            inline for (endpoints, 0..) |E, i| {
                result[i] = .{ .method = E.http_method, .segments = parse(E.route_path) };
            }
            return result;
        }

        /// Match is allocation-free. Route descriptions and segments are
        /// compile-time constants; no route pattern is parsed per request.
        pub fn match(method: status.Method, path: []const u8) ?Match {
            const patterns = comptime makePatterns();
            // Small APIs benefit from a fully unrolled decision path. Large
            // APIs use a compact descriptor table to cap code size.
            if (comptime prefer_specialized_matcher) {
                inline for (patterns, 0..) |pattern, index| {
                    if (method == pattern.method or (method == .HEAD and pattern.method == .GET)) {
                        var params: Params = .{};
                        if (matchPath(pattern.segments, path, &params)) return .{ .index = index, .params = params };
                    }
                }
            } else {
                for (patterns, 0..) |pattern, index| {
                    if (method != pattern.method and !(method == .HEAD and pattern.method == .GET)) continue;
                    var params: Params = .{};
                    if (matchPathDynamic(pattern.segments, path, &params)) return .{ .index = index, .params = params };
                }
            }
            return null;
        }

        pub fn dispatch(index: usize, c: anytype) anyerror!void {
            inline for (endpoints, 0..) |E, candidate| {
                if (index == candidate) return E.handle(c);
            }
            return error.InvalidStaticRouteIndex;
        }
    };
}

fn matchPathDynamic(segments: []const Segment, path_in: []const u8, params: *Params) bool {
    var path = path_in;
    if (path.len > 0 and path[0] == '/') path = path[1..];
    if (path.len > 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    var pos: usize = 0;
    for (segments, 0..) |segment, segment_index| {
        if (segment.kind == .wildcard) {
            if (params.len >= params.names.len) return false;
            params.names[params.len] = segment.text;
            params.values[params.len] = path[pos..];
            params.len += 1;
            return true;
        }
        if (pos > path.len) return false;
        const rest = path[pos..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (end == 0 and rest.len == 0) return false;
        const value = rest[0..end];
        if (segment.kind == .literal) {
            if (!std.mem.eql(u8, segment.text, value)) return false;
        } else {
            if (params.len >= params.names.len) return false;
            params.names[params.len] = segment.text;
            params.values[params.len] = value;
            params.len += 1;
        }
        pos += end;
        if (pos < path.len and path[pos] == '/') pos += 1;
        if (segment_index + 1 == segments.len and pos != path.len) return false;
    }
    return pos == path.len;
}

fn matchPath(comptime segments: []const Segment, path_in: []const u8, params: *Params) bool {
    var path = path_in;
    if (path.len > 0 and path[0] == '/') path = path[1..];
    if (path.len > 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    var pos: usize = 0;
    inline for (segments, 0..) |segment, segment_index| {
        if (segment.kind == .wildcard) {
            if (params.len >= params.names.len) return false;
            params.names[params.len] = segment.text;
            params.values[params.len] = path[pos..];
            params.len += 1;
            return true;
        }
        if (pos > path.len) return false;
        const rest = path[pos..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        if (end == 0 and rest.len == 0) return false;
        const value = rest[0..end];
        if (segment.kind == .literal) {
            if (!std.mem.eql(u8, segment.text, value)) return false;
        } else {
            if (params.len >= params.names.len) return false;
            params.names[params.len] = segment.text;
            params.values[params.len] = value;
            params.len += 1;
        }
        pos += end;
        if (pos < path.len and path[pos] == '/') pos += 1;
        if (segment_index + 1 == segments.len and pos != path.len) return false;
    }
    return pos == path.len;
}

test "static graph matches literals, parameters, and wildcards" {
    const E = struct {
        pub const http_method: status.Method = .GET;
        pub const route_path = "/users/:id/*rest";
        pub fn register(_: anytype) !void {}
        pub fn handle(_: anytype) !void {}
    };
    const R = Graph(.{E});
    const found = R.match(.GET, "/users/42/profile/avatar") orelse return error.NotFound;
    try std.testing.expectEqualStrings("42", found.params.get("id").?);
    try std.testing.expectEqualStrings("profile/avatar", found.params.get("rest").?);
}
