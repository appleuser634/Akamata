const std = @import("std");
const am = @import("akamata");

const App = struct {};
fn dummy(_: *am.Ctx(App)) !void {}

test "deep nested static path matches" {
    const R = am.Router(App);
    const router = R.build(&.{R.post("/api/auth/register", dummy)});
    var n: [16][]const u8 = undefined;
    var v: [16][]const u8 = undefined;
    const m = router.match(.POST, "/api/auth/register", &n, &v);
    try std.testing.expect(m != null);
}

test "static path with three segments matches" {
    const R = am.Router(App);
    const router = R.build(&.{R.get("/api/public/ping", dummy)});
    var n: [16][]const u8 = undefined;
    var v: [16][]const u8 = undefined;
    const m = router.match(.GET, "/api/public/ping", &n, &v);
    try std.testing.expect(m != null);
}

test "ordered list still picks middle entry" {
    const R = am.Router(App);
    const router = R.build(&.{
        R.get("/api/public/ping", dummy),
        R.post("/api/auth/register", dummy),
        R.post("/api/auth/login", dummy),
        R.get("/api/ping", dummy),
    });
    var n: [16][]const u8 = undefined;
    var v: [16][]const u8 = undefined;
    try std.testing.expect(router.match(.POST, "/api/auth/login", &n, &v) != null);
    try std.testing.expect(router.match(.GET, "/api/ping", &n, &v) != null);
}
