// Pulls in the model sub-modules' inline tests via the public akamata
// namespace, so zig test registers them. Each `_ = ...` reference ensures
// the corresponding file is compiled and its `test` blocks are picked up.

const am = @import("akamata");

comptime {
    _ = am.model.schema;
    _ = am.model.ddl;
    _ = am.model.validate_mod;
    _ = am.model.query;
    _ = am.model.migrate;
    _ = am.model.relations;
    _ = am.model.preload;
}
