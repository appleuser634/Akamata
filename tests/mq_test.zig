const std = @import("std");
const am = @import("akamata");

test "mq module exposes Publisher type" {
    // Symbol-presence smoke test: the actual broker connection is exercised
    // via integration only (requires a running MQTT broker).
    const T = am.mq.Publisher;
    _ = T;
}
