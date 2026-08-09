.{
    .name = .{{NAME_ENUM}},
    .version = "0.0.1",
    .fingerprint = {{FINGERPRINT}},
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        // Commit-pinned for reproducible builds. During Akamata development,
        // override it temporarily with: zig build --fork=/path/to/Akamata
        .akamata = .{
            .url = "https://github.com/appleuser634/Akamata/archive/45b06800d0b05f67fc99d6123ae5cc6b565e2d00.tar.gz",
            .hash = "akamata-0.0.1-uJIoI9fbpQHfbWVXyPzUXH_mCJm40Og5sMf1Fd9g7_dh",
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
