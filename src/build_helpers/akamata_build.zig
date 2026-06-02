// Build helper: user projects import this from akamata to bootstrap their
// build.zig with one function call.
//
// Usage in a user project's build.zig:
//
//   const std = @import("std");
//   const am = @import("akamata");
//
//   pub fn build(b: *std.Build) void {
//       am.akamata_build.app(b, .{
//           .name = "my-app",
//           .root_source_file = "src/main.zig",
//       });
//   }

const std = @import("std");

pub const Backend = enum { native, workers };

pub const AppOptions = struct {
    name: []const u8,
    /// Path to the user's main.zig relative to build root.
    root_source_file: []const u8,
    /// If true and backend=native, link OpenSSL (for HTTPS client / FCM).
    openssl: bool = false,
    /// Pass to akamata's installed module. Usually leave null and we'll add it.
    akamata_dep_name: []const u8 = "akamata",
};

/// Wire up an executable for the given app source. Adds `-Dbackend`,
/// `-Dtarget`, `-Doptimize`, and a `run` step.
pub fn app(b: *std.Build, opts: AppOptions) void {
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(Backend, "backend", "deployment backend (native | workers)") orelse .native;

    const native_target = b.standardTargetOptions(.{});
    const target = switch (backend) {
        .native => native_target,
        .workers => b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
    };

    const dep = b.dependency(opts.akamata_dep_name, .{
        .backend = backend,
        .openssl = opts.openssl,
        .target = target,
        .optimize = optimize,
    });
    const yt_mod = dep.module("akamata");

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(opts.root_source_file),
            .target = target,
            .optimize = if (backend == .workers) .ReleaseSmall else optimize,
            .imports = &.{.{ .name = "akamata", .module = yt_mod }},
        }),
    });

    if (backend == .workers) {
        exe.entry = .disabled;
        exe.rdynamic = true;
    }
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "run the app (native)").dependOn(&run.step);
}
