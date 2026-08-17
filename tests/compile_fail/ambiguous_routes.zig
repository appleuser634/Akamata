const am = @import("akamata");
fn h(_: *am.Context(struct {})) !void {}
const A = am.contract.Endpoint(.GET, "/users/:id", h, .{ .operation_id = "a" });
const B = am.contract.Endpoint(.GET, "/users/:name", h, .{ .operation_id = "b" });
comptime {
    am.contract.validateGraph(.{ A, B });
}
