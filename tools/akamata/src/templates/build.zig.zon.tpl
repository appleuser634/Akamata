.{
    .name = .{{NAME_ENUM}},
    .version = "0.0.1",
    .fingerprint = {{FINGERPRINT}},
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        // Pinned to a release-compatible Akamata revision. During Akamata
        // development, override it with: zig build --fork=/path/to/Akamata
        .akamata = .{
            .url = "https://github.com/appleuser634/Akamata/archive/refs/tags/v0.0.1.tar.gz",
            .hash = "akamata-0.0.1-uJIoIyrDpgGW_zcWhJ23IXuXNGR1Qz9T7-jhI0sKk3gg",
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
