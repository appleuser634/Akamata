.{
    .name = .{{NAME_ENUM}},
    .version = "0.0.1",
    .fingerprint = {{FINGERPRINT}},
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        // Update this `path` to where you cloned Akamata, or replace with a
        // `url`/`hash` entry once Akamata is released as a Zig package.
        .akamata = .{ .path = "../Akamata" },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "README.md",
    },
}
