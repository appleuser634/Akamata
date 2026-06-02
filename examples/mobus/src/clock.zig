const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

const Native = struct {
    extern "c" fn time(t: ?*i64) i64;
};
const Wasm = struct {
    extern "akamata_env" fn akamata_unix_seconds() i64;
};

pub fn unixSeconds() i64 {
    if (is_wasm) return Wasm.akamata_unix_seconds();
    if (builtin.os.tag == .windows) return 0;
    return Native.time(null);
}
