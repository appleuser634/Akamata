const am = @import("akamata");
comptime {
    am.capability.requireKinds("route POST /upload", &.{.filesystem}, .workers);
}
