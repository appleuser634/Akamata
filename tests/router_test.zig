const std = @import("std");
const am = @import("akamata");

const App = struct {};
const R = am.Router(App);

fn dummy(_: *am.Ctx(App)) !void {}

const router = R.build(&.{
    R.get("/", dummy),
    R.get("/health", dummy),
    R.get("/rooms", dummy),
    R.post("/rooms", dummy),
    R.get("/rooms/:id", dummy),
    R.get("/rooms/:id/messages", dummy),
    R.ws("/rooms/:id/ws", dummy),
    R.get("/files/*rest", dummy),
});

test "matches static route" {
    var names: [8][]const u8 = undefined;
    var values: [8][]const u8 = undefined;
    const m = router.match(.GET, "/health", &names, &values);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 0), m.?.params.names.len);
}

test "matches param route and captures value" {
    var names: [8][]const u8 = undefined;
    var values: [8][]const u8 = undefined;
    const m = router.match(.GET, "/rooms/42/messages", &names, &values);
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("id", m.?.params.names[0]);
    try std.testing.expectEqualStrings("42", m.?.params.values[0]);
}

test "returns null on method mismatch" {
    var names: [8][]const u8 = undefined;
    var values: [8][]const u8 = undefined;
    const m = router.match(.DELETE, "/rooms", &names, &values);
    try std.testing.expectEqual(@as(?am.Router(App).Match, null), m);
}

test "ws route is selected" {
    var names: [8][]const u8 = undefined;
    var values: [8][]const u8 = undefined;
    const m = router.match(.GET, "/rooms/7/ws", &names, &values);
    try std.testing.expect(m != null);
    try std.testing.expectEqual(am.legacy.RouteKind.ws, m.?.kind);
}

test "wildcard captures rest of path" {
    var names: [8][]const u8 = undefined;
    var values: [8][]const u8 = undefined;
    const m = router.match(.GET, "/files/a/b/c.txt", &names, &values);
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("rest", m.?.params.names[0]);
    try std.testing.expectEqualStrings("a/b/c.txt", m.?.params.values[0]);
}
