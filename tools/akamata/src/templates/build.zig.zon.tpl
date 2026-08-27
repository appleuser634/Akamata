.{
    .name = .{{NAME_ENUM}},
    .version = "0.0.1",
    .fingerprint = {{FINGERPRINT}},
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        // Pinned to a release-compatible Akamata revision. During Akamata
        // development, override it with: zig build --fork=/path/to/Akamata
        .akamata = .{
            .url = "https://github.com/moribit/Akamata/archive/refs/tags/v0.1.3.tar.gz",
            .hash = "akamata-0.1.3-uJIoIxf5LAFuRQ45_Lm7Axug4u7ZZApnO5XwzFmiVyQ8",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "migrations",
        "deploy",
        "README.md",
    },
}
