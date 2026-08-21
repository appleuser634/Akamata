const am = @import("akamata");
const Env = struct { files: am.binding.R2("FILES") };
comptime {
    am.binding.validate(Env, .native);
}
test {
    _ = Env;
}
