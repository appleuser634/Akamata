const std = @import("std");
const am = @import("akamata");

const State = struct {};

fn runtimeHandler(c: *am.Context(State)) !void {
    try c.text(try c.req.param("id"));
}

const GetUser = am.contract.Endpoint(.GET, "/users/:id", runtimeHandler, .{ .operation_id = "getUser" });
const Files = am.contract.Endpoint(.GET, "/files/*rest", runtimeHandler, .{ .operation_id = "files" });
const Routes = am.Routes(.{ GetUser, Files });

test "static graph and runtime registration have matching behavior" {
    comptime Routes.validate();
    const direct = Routes.match(.GET, "/users/42") orelse return error.NotFound;
    try std.testing.expectEqualStrings("42", direct.params.get("id").?);

    var app = am.App(State).init(std.testing.allocator, .{});
    defer app.deinit();
    _ = try app.mountStatic(Routes);
    var client = am.testing.Client(@TypeOf(app)).init(std.testing.allocator, &app);
    var response = try client.get("/users/42").send();
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("42", response.body);
}

const Input = struct {
    id: am.contract.Path(u64, "id"),
    limit: am.contract.Query(?u32, "limit"),
};
const User = struct { id: u64 };
const LookupError = error{ UserNotFound, DatabaseUnavailable };

fn typedHandler(_: *am.Context(State), input: Input) LookupError!User {
    if (input.id.value == 0) return error.UserNotFound;
    return .{ .id = input.id.value };
}

const Typed = am.contract.TypedEndpoint(
    State,
    .GET,
    "/typed/:id",
    typedHandler,
    .{ .UserNotFound = am.Status.not_found, .DatabaseUnavailable = am.Status.service_unavailable },
    .{ .operation_id = "typedUser" },
);

test "typed handler drives HTTP errors and inferred response" {
    var app = am.App(State).init(std.testing.allocator, .{});
    defer app.deinit();
    try Typed.register(&app);
    var client = am.testing.Client(@TypeOf(app)).init(std.testing.allocator, &app);
    var ok = try client.get("/typed/7").send();
    defer ok.deinit();
    try std.testing.expectEqual(@as(u16, 200), ok.status);
    try std.testing.expect(std.mem.indexOf(u8, ok.body, "\"id\":7") != null);
    var missing = try client.get("/typed/0").send();
    defer missing.deinit();
    try std.testing.expectEqual(@as(u16, 404), missing.status);

    const spec = try am.openapi.generate(@TypeOf(app), &app, std.testing.allocator, .{});
    defer std.testing.allocator.free(spec);
    try std.testing.expect(std.mem.indexOf(u8, spec, "typedUser") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "DatabaseUnavailable") != null);
}

test "capability matrix distinguishes native and Workers" {
    try std.testing.expect(am.capability.available(.native, .filesystem));
    try std.testing.expect(!am.capability.available(.workers, .filesystem));
    try std.testing.expect(am.capability.available(.workers, .d1));
}

test "DI graph emits dependency-first order" {
    const Config = struct {};
    const Database = struct {};
    const Session = struct {};
    const PConfig = am.di.Provider(Config, .application, &.{});
    const PDatabase = am.di.Provider(Database, .application, &.{Config});
    const PSession = am.di.Provider(Session, .request, &.{Database});
    const G = am.di.Graph(&.{ PSession, PDatabase, PConfig });
    try std.testing.expectEqual(@as(usize, 2), G.order[0]);
    try std.testing.expectEqual(@as(usize, 1), G.order[1]);
    try std.testing.expectEqual(@as(usize, 0), G.order[2]);
}

test "static middleware preserves declaration order" {
    const Ctx = struct { order: [3]u8 = undefined, len: usize = 0 };
    const First = struct {
        pub fn call(c: *Ctx, next: *const fn (*Ctx) anyerror!void) !void {
            c.order[c.len] = 1;
            c.len += 1;
            try next(c);
        }
    };
    const Second = struct {
        pub fn call(c: *Ctx, next: *const fn (*Ctx) anyerror!void) !void {
            c.order[c.len] = 2;
            c.len += 1;
            try next(c);
        }
    };
    const terminal = struct {
        fn call(c: *Ctx) !void {
            c.order[c.len] = 3;
            c.len += 1;
        }
    }.call;
    const Chain = am.static_middleware.Chain(Ctx, &.{ First, Second }, terminal);
    var c: Ctx = .{};
    try Chain.run(&c);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, c.order[0..c.len]);
}

test "SQL descriptor validates placeholders and row types" {
    const Q = am.db.Query(
        "select id, name from users where id = ?",
        std.meta.Tuple(&.{u64}),
        struct { id: u64, name: []const u8 },
    );
    try std.testing.expectEqual(@as(usize, 1), Q.placeholder_count);
}

test "static DB adapter dispatches directly to its concrete backend" {
    const Backend = struct {
        calls: usize = 0,
        pub fn prepare(_: *@This(), _: []const u8) error{}!u8 {
            return 7;
        }
        pub fn exec(self: *@This(), _: []const u8) error{}!void {
            self.calls += 1;
        }
        pub fn close(_: *@This()) void {}
    };
    var database: am.db.Static(Backend) = .{ .backend = .{} };
    try database.exec("select 1");
    try std.testing.expectEqual(@as(usize, 1), database.backend.calls);
    try std.testing.expectEqual(@as(u8, 7), try database.prepare("select 1"));
}
