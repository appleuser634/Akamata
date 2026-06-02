const std = @import("std");
const ctx_mod = @import("legacy_ctx.zig");

pub fn Next(comptime App: type) type {
    return struct {
        const Self = @This();
        chain: []const Middleware(App),
        terminal: *const fn (*ctx_mod.Ctx(App)) anyerror!void,
        index: usize,

        pub fn run(self: Self, ctx: *ctx_mod.Ctx(App)) anyerror!void {
            if (self.index >= self.chain.len) {
                return self.terminal(ctx);
            }
            const mw = self.chain[self.index];
            const next: Self = .{
                .chain = self.chain,
                .terminal = self.terminal,
                .index = self.index + 1,
            };
            return mw.call(ctx, next);
        }
    };
}

pub fn Middleware(comptime App: type) type {
    return struct {
        name: []const u8 = "anon",
        call: *const fn (ctx: *ctx_mod.Ctx(App), next: Next(App)) anyerror!void,
    };
}

/// Convenience: assemble a middleware chain and execute terminal handler.
pub fn run(
    comptime App: type,
    chain: []const Middleware(App),
    terminal: *const fn (*ctx_mod.Ctx(App)) anyerror!void,
    ctx: *ctx_mod.Ctx(App),
) anyerror!void {
    const n: Next(App) = .{ .chain = chain, .terminal = terminal, .index = 0 };
    return n.run(ctx);
}

/// Built-in middlewares
pub fn requestLog(comptime App: type) Middleware(App) {
    const Impl = struct {
        fn call(ctx: *ctx_mod.Ctx(App), next: Next(App)) anyerror!void {
            next.run(ctx) catch |err| {
                std.log.err("{s} {s} -> error {t}", .{
                    @tagName(ctx.req.method),
                    ctx.req.path,
                    err,
                });
                return err;
            };
            std.log.info("{s} {s} -> {d}", .{
                @tagName(ctx.req.method),
                ctx.req.path,
                ctx.res.status_code,
            });
        }
    };
    return .{ .name = "requestLog", .call = Impl.call };
}

pub fn recover(comptime App: type) Middleware(App) {
    const Impl = struct {
        fn call(ctx: *ctx_mod.Ctx(App), next: Next(App)) anyerror!void {
            next.run(ctx) catch |err| {
                std.log.err("uncaught handler error: {t}", .{err});
                ctx.res.body.clearRetainingCapacity();
                ctx.res.headers.clearRetainingCapacity();
                ctx.res.setStatus(500);
                ctx.res.json(.{ .error_kind = "internal", .message = "internal server error" }) catch {};
            };
        }
    };
    return .{ .name = "recover", .call = Impl.call };
}
