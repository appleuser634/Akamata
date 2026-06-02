// Static file middleware (native only). Serves files from a root directory.
// On Workers this is a no-op (use the JS layer or `assets` bindings instead).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const app_mod = @import("../app.zig");
const mime = @import("../http/mime.zig");

pub const Options = struct {
    root: []const u8,
    /// Required prefix in the request URL. Matched files come from `root` + (req.path - prefix).
    prefix: []const u8 = "/",
    /// If the resolved path is a directory, append this and try again.
    index: ?[]const u8 = "index.html",
};

const is_native = build_options.backend == .native;

pub fn serveStatic(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            if (!is_native) return next.run(c);
            if (!std.mem.eql(u8, c.req.method(), "GET")) return next.run(c);
            const p = c.req.path();
            if (!std.mem.startsWith(u8, p, opts.prefix)) return next.run(c);

            const rel = p[opts.prefix.len..];
            const safe = if (rel.len == 0 or std.mem.indexOf(u8, rel, "..") != null)
                if (opts.index) |idx| idx else return next.run(c)
            else
                rel;

            const full = try std.fmt.allocPrint(c.arena, "{s}/{s}", .{ opts.root, safe });

            const path_z = try c.arena.dupeZ(u8, full);
            const FILE = opaque {};
            const Lib = struct {
                extern "c" fn fopen(p2: [*:0]const u8, m: [*:0]const u8) ?*FILE;
                extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, s: *FILE) usize;
                extern "c" fn fclose(s: *FILE) c_int;
            };
            const f = Lib.fopen(path_z.ptr, "rb") orelse return next.run(c);
            defer _ = Lib.fclose(f);

            var buf: [8192]u8 = undefined;
            var collected: std.ArrayList(u8) = .empty;
            while (true) {
                const n = Lib.fread(&buf, 1, buf.len, f);
                if (n == 0) break;
                try collected.appendSlice(c.arena, buf[0..n]);
            }
            try c.header("content-type", mime.fromExt(full));
            c.status(200);
            try c.body(collected.items);
        }
    };
    return .{ .name = "serveStatic", .call = Impl.call };
}
