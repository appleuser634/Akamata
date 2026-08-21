const am = @import("akamata");
const Event = union { value: struct { id: u64 } };
const P = am.events.Protocol(Event, 1);
test {
    _ = P;
}
