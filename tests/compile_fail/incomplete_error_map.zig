const am = @import("akamata");
fn h() error{ Missing, Unavailable }!void {}
comptime {
    am.contract.validateErrorMap(h, .{ .Missing = am.Status.not_found });
}
