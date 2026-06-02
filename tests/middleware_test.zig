const std = @import("std");
const am = @import("akamata");

const App = struct { trace: std.ArrayList(u8) };

fn pushChar(comptime ch: u8) am.legacy.middleware.Middleware(App) {
    const Impl = struct {
        fn call(ctx: *am.Ctx(App), next: am.legacy.middleware.Next(App)) anyerror!void {
            try ctx.app.trace.append(std.testing.allocator, ch);
            try next.run(ctx);
            try ctx.app.trace.append(std.testing.allocator, std.ascii.toUpper(ch));
        }
    };
    return .{ .name = "pushChar", .call = Impl.call };
}

fn terminal(ctx: *am.Ctx(App)) anyerror!void {
    try ctx.app.trace.append(std.testing.allocator, '|');
}

test "middleware chain runs in order with proper before/after wrapping" {
    var app: App = .{ .trace = .empty };
    defer app.trace.deinit(std.testing.allocator);

    var req: am.Request = .{
        .method = .GET,
        .raw_method = "GET",
        .path = "/",
        .query = "",
        .version = "HTTP/1.1",
        .headers = &.{},
        .body = "",
        .keep_alive = true,
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var res: am.Response = .init(arena);

    var ctx: am.Ctx(App) = .{
        .app = &app,
        .req = &req,
        .res = &res,
        .arena = arena,
    };

    const chain = [_]am.legacy.middleware.Middleware(App){ pushChar('a'), pushChar('b'), pushChar('c') };
    try am.middleware.run(App, &chain, terminal, &ctx);
    try std.testing.expectEqualStrings("abc|CBA", app.trace.items);
}
