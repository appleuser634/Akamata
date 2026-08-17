const am = @import("akamata");
const State = struct {};
const Inputs = struct { other: am.contract.Path(u64, "other") };
fn h(_: *am.Context(State), _: Inputs) !void {}
const Bound = am.contract.BoundForPath(State, "/users/:id", Inputs, h);
comptime {
    _ = Bound;
}
