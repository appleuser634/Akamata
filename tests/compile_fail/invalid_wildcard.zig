const am = @import("akamata");
fn h(_: *am.Context(struct {})) !void {}
const A = am.contract.Endpoint(.GET, "/files/*rest/more", h, .{});
comptime {
    am.contract.validateGraph(.{A});
}
