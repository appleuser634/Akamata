const am = @import("akamata");
fn h(_: *am.Context(struct {})) !void {}
const A = am.contract.Endpoint(.GET, "/a", h, .{ .operation_id = "same" });
const B = am.contract.Endpoint(.POST, "/b", h, .{ .operation_id = "same" });
comptime {
    am.contract.validateGraph(.{ A, B });
}
