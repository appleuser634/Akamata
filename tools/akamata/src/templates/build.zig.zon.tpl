.{
    .name = .{{NAME_ENUM}},
    .version = "0.0.1",
    .fingerprint = {{FINGERPRINT}},
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        // Pinned to a release-compatible Akamata revision. During Akamata
        // development, override it with: zig build --fork=/path/to/Akamata
        .akamata = .{
            .url = "https://github.com/appleuser634/Akamata/archive/97ee6d5d2aa9104a72b84c484885ab52abf9e9fd.tar.gz",
            .hash = "akamata-0.0.1-uJIoI66spgGfuOjGOExyIFkbLW9VVaRuyHBjvwVgB4SU",
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
