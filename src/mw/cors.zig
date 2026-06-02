const std = @import("std");
const app_mod = @import("../app.zig");

pub const Options = struct {
    origin: []const u8 = "*",
    allow_methods: []const u8 = "GET,POST,PUT,DELETE,PATCH,OPTIONS",
    allow_headers: []const u8 = "content-type,authorization",
    expose_headers: []const u8 = "",
    max_age: ?u32 = null,
    credentials: bool = false,
};

pub fn cors(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            try c.header("access-control-allow-origin", opts.origin);
            if (opts.credentials) try c.header("access-control-allow-credentials", "true");
            if (opts.expose_headers.len > 0) try c.header("access-control-expose-headers", opts.expose_headers);

            // Preflight short-circuit
            if (std.mem.eql(u8, c.req.method(), "OPTIONS")) {
                try c.header("access-control-allow-methods", opts.allow_methods);
                try c.header("access-control-allow-headers", opts.allow_headers);
                if (opts.max_age) |m| {
                    var buf: [16]u8 = undefined;
                    const v = try std.fmt.bufPrint(&buf, "{d}", .{m});
                    try c.header("access-control-max-age", v);
                }
                c.status(204);
                return;
            }
            try next.run(c);
        }
    };
    return .{ .name = "cors", .call = Impl.call };
}
