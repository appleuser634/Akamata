const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const Backend = enum { native, workers };
    const backend = b.option(Backend, "backend", "deployment backend (native | workers)") orelse .native;

    const native_target = b.standardTargetOptions(.{});
    const target = switch (backend) {
        .native => native_target,
        .workers => b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
    };

    const am = b.dependency("akamata", .{
        .backend = backend,
        .target = target,
        .optimize = optimize,
    });

    const root = switch (backend) {
        .native => "src/main.zig",
        .workers => "src/worker.zig",
    };

    const exe = b.addExecutable(.{
        .name = if (backend == .workers) "{{NAME}}_worker" else "{{NAME}}",
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            // Respect -Doptimize. `akamata deploy --workers` defaults to
            // ReleaseFast (override with --optimize=ReleaseSmall for the
            // smallest bundle).
            .optimize = optimize,
            .imports = &.{.{ .name = "akamata", .module = am.module("akamata") }},
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
