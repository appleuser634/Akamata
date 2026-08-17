const std = @import("std");
const am = @import("akamata");
const opts = @import("router_bench_options");

const State = struct {};
const Ctx = am.Context(State);

fn terminal(c: *Ctx) !void {
    try c.text("ok");
}

const NoopStatic = struct {
    pub fn call(c: *Ctx, next: *const fn (*Ctx) anyerror!void) !void {
        return next(c);
    }
};

fn staticHandler() *const fn (*Ctx) anyerror!void {
    const middlewares = [_]type{NoopStatic} ** opts.middleware_count;
    return am.static_middleware.Chain(Ctx, &middlewares, terminal).run;
}

fn dynamicMiddleware() am.Middleware(State) {
    return .{ .name = "noop", .call = struct {
        fn call(c: *Ctx, next: am.Next(State)) anyerror!void {
            return next.run(c);
        }
    }.call };
}

fn routePath(comptime index: usize) []const u8 {
    return switch (opts.route_kind) {
        .static => std.fmt.comptimePrint("/r/{d}", .{index}),
        .parameter => std.fmt.comptimePrint("/r/{d}/:id", .{index}),
        .wildcard => std.fmt.comptimePrint("/r/{d}/*rest", .{index}),
    };
}

fn endpoint(comptime index: usize) type {
    return am.contract.Endpoint(.GET, routePath(index), staticHandler(), .{
        .operation_id = std.fmt.comptimePrint("route{d}", .{index}),
    });
}

fn routeTypes() [opts.route_count]type {
    @setEvalBranchQuota(2_000_000);
    var result: [opts.route_count]type = undefined;
    for (0..opts.route_count) |i| result[i] = endpoint(i);
    return result;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var app = am.App(State).init(gpa, .{});
    defer app.deinit();
    const endpoints = comptime routeTypes();
    const Graph = am.Routes(endpoints);
    if (opts.router == .static) {
        _ = try app.mountStatic(Graph);
    } else {
        inline for (endpoints) |E| try E.register(&app);
        inline for (0..opts.middleware_count) |_| _ = try app.useAll(dynamicMiddleware());
    }
    std.log.info("router={s} routes={d} kind={s} middleware={d}", .{
        @tagName(opts.router), opts.route_count, @tagName(opts.route_kind), opts.middleware_count,
    });
    try app.serve(.{ .port = 8090, .accept_thread_count = 8, .max_requests_per_connection = 1_000_000 });
}
