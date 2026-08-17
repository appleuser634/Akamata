const am = @import("akamata");
const State = struct {};
const Body = struct { value: u32 };
const Inputs = struct { first: am.contract.Json(Body), second: am.contract.Json(Body) };
fn h(_: *am.Context(State), _: Inputs) !void {}
const Bound = am.contract.BoundForPath(State, "/body", Inputs, h);
comptime {
    _ = Bound;
}
