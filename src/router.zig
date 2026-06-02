const std = @import("std");
const status = @import("http/status.zig");
const ctx_mod = @import("legacy_ctx.zig");

pub const Method = status.Method;

pub const RouteKind = enum { http, ws };

pub fn Handler(comptime App: type) type {
    return *const fn (ctx: *ctx_mod.Ctx(App)) anyerror!void;
}

pub fn Route(comptime App: type) type {
    return struct {
        method: Method,
        kind: RouteKind,
        path: []const u8,
        handler: Handler(App),
        /// Parsed once at build() time:
        segments: []const Segment,

        pub const Segment = struct {
            kind: enum { static, param, wildcard },
            text: []const u8,
        };
    };
}

pub fn Router(comptime App: type) type {
    return struct {
        const Self = @This();
        pub const Match = struct {
            handler: Handler(App),
            kind: RouteKind,
            params: ctx_mod.Params,
        };

        routes: []const Route(App),

        pub fn build(comptime routes: []const Route(App)) Self {
            return .{ .routes = routes };
        }

        pub fn match(
            self: Self,
            method: Method,
            path: []const u8,
            buf_names: [][]const u8,
            buf_values: [][]const u8,
        ) ?Match {
            const segs = splitPath(path);
            for (self.routes) |r| {
                if (r.method != method) continue;
                const m = matchRoute(r, segs, buf_names, buf_values) orelse continue;
                return .{ .handler = r.handler, .kind = r.kind, .params = m };
            }
            return null;
        }

        pub fn hasPath(self: Self, path: []const u8) bool {
            const segs = splitPath(path);
            var dummy_names: [16][]const u8 = undefined;
            var dummy_values: [16][]const u8 = undefined;
            for (self.routes) |r| {
                if (matchRoute(r, segs, &dummy_names, &dummy_values) != null) return true;
            }
            return false;
        }

        /// Helpers to declare routes
        pub fn get(comptime path: []const u8, h: Handler(App)) Route(App) {
            return route(.GET, .http, path, h);
        }
        pub fn post(comptime path: []const u8, h: Handler(App)) Route(App) {
            return route(.POST, .http, path, h);
        }
        pub fn put(comptime path: []const u8, h: Handler(App)) Route(App) {
            return route(.PUT, .http, path, h);
        }
        pub fn delete(comptime path: []const u8, h: Handler(App)) Route(App) {
            return route(.DELETE, .http, path, h);
        }
        pub fn patch(comptime path: []const u8, h: Handler(App)) Route(App) {
            return route(.PATCH, .http, path, h);
        }
        pub fn ws(comptime path: []const u8, h: Handler(App)) Route(App) {
            return route(.GET, .ws, path, h);
        }

        fn route(
            comptime method: Method,
            comptime kind: RouteKind,
            comptime path: []const u8,
            h: Handler(App),
        ) Route(App) {
            const segs = comptime parseSegments(path);
            return .{
                .method = method,
                .kind = kind,
                .path = path,
                .handler = h,
                .segments = segs,
            };
        }

        fn parseSegments(comptime path: []const u8) []const Route(App).Segment {
            comptime var segs: []const Route(App).Segment = &.{};
            comptime var p = path;
            // Strip leading and trailing slash so "/" yields zero segments,
            // matching splitPath() behavior at request time.
            if (p.len > 0 and p[0] == '/') p = p[1..];
            if (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
            if (p.len == 0) return segs;
            comptime var i: usize = 0;
            comptime var start: usize = 0;
            inline while (i < p.len) : (i += 1) {
                if (p[i] == '/') {
                    segs = segs ++ [_]Route(App).Segment{makeSegment(p[start..i])};
                    start = i + 1;
                }
            }
            segs = segs ++ [_]Route(App).Segment{makeSegment(p[start..p.len])};
            return segs;
        }

        fn makeSegment(comptime s: []const u8) Route(App).Segment {
            if (s.len > 0 and s[0] == ':') return .{ .kind = .param, .text = s[1..] };
            if (s.len > 0 and s[0] == '*') return .{ .kind = .wildcard, .text = s[1..] };
            return .{ .kind = .static, .text = s };
        }
    };
}

const PathSegs = struct {
    segs: [32][]const u8,
    len: usize,
};

fn splitPath(path: []const u8) PathSegs {
    var out: PathSegs = .{ .segs = undefined, .len = 0 };
    var p = path;
    if (p.len > 0 and p[0] == '/') p = p[1..];
    if (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (p.len == 0) return out;

    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (out.len >= out.segs.len) break;
        out.segs[out.len] = seg;
        out.len += 1;
    }
    return out;
}

fn matchRoute(
    r: anytype,
    segs: PathSegs,
    buf_names: [][]const u8,
    buf_values: [][]const u8,
) ?ctx_mod.Params {
    var n: usize = 0;
    var i: usize = 0;
    while (i < r.segments.len) : (i += 1) {
        const rs = r.segments[i];
        if (rs.kind == .wildcard) {
            if (n >= buf_names.len) return null;
            buf_names[n] = if (rs.text.len == 0) "_" else rs.text;
            // join remaining segments
            if (i >= segs.len) {
                buf_values[n] = "";
            } else {
                // Compute slice from segs[i] start to end of path. Since segs are slices into the same path,
                // we reconstruct via pointer arithmetic on segs[i] and segs[segs.len-1].
                const first = segs.segs[i];
                const last = segs.segs[segs.len - 1];
                const start = @intFromPtr(first.ptr);
                const end = @intFromPtr(last.ptr) + last.len;
                buf_values[n] = @as([*]const u8, @ptrFromInt(start))[0 .. end - start];
            }
            n += 1;
            return .{ .names = buf_names[0..n], .values = buf_values[0..n] };
        }
        if (i >= segs.len) return null;
        const ps = segs.segs[i];
        switch (rs.kind) {
            .static => if (!std.mem.eql(u8, rs.text, ps)) return null,
            .param => {
                if (n >= buf_names.len) return null;
                buf_names[n] = rs.text;
                buf_values[n] = ps;
                n += 1;
            },
            .wildcard => unreachable,
        }
    }
    if (i != segs.len) return null;
    return .{ .names = buf_names[0..n], .values = buf_values[0..n] };
}
