const std = @import("std");

pub const Backend = enum { native, workers };
pub const Example = enum { chat, mobus, guestbook, bench, tasks };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(Backend, "backend", "deployment backend (native | workers)") orelse .native;
    const example = b.option(Example, "example", "which example to build (chat | mobus | guestbook | bench)") orelse .chat;
    // OpenSSL is opt-in and only needed for FCM RS256 signing. The HTTPS
    // client and Turso path now use std.crypto.tls — no OpenSSL needed.
    // Enable with `-Dopenssl=true` if you build the FCM push example.
    const with_openssl = b.option(bool, "openssl", "link OpenSSL (only needed for FCM RS256 signing)") orelse false;

    const native_target = b.standardTargetOptions(.{});
    const target = switch (backend) {
        .native => native_target,
        .workers => b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
    };

    // Publish as a named module so downstream consumers can do
    // `dep.module("akamata")` from their own build.zig.
    const am_mod = b.addModule("akamata", .{
        .root_source_file = b.path("src/akamata.zig"),
        .target = target,
        .optimize = optimize,
    });

    const opts = b.addOptions();
    opts.addOption(Backend, "backend", backend);
    opts.addOption(bool, "with_openssl", with_openssl);
    am_mod.addOptions("build_options", opts);

    if (backend == .native) {
        const sqlite_flags = &[_][]const u8{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_USE_URI=1",
            "-std=c99",
        };
        am_mod.addCSourceFile(.{
            .file = b.path("third_party/sqlite/sqlite3.c"),
            .flags = sqlite_flags,
        });
        am_mod.addCSourceFile(.{
            .file = b.path("third_party/sqlite/akamata_sqlite_shim.c"),
            .flags = sqlite_flags,
        });
        am_mod.addIncludePath(b.path("third_party/sqlite"));
        am_mod.link_libc = true;
        if (with_openssl) {
            am_mod.linkSystemLibrary("ssl", .{});
            am_mod.linkSystemLibrary("crypto", .{});
        }
    }

    // === Example targets ===
    const example_root = switch (example) {
        .chat => switch (backend) {
            .native => "examples/chat/src/main.zig",
            .workers => "examples/chat/src/worker.zig",
        },
        .mobus => switch (backend) {
            .native => "examples/mobus/src/main.zig",
            .workers => "examples/mobus/src/worker.zig",
        },
        .guestbook => switch (backend) {
            .native => "examples/guestbook/src/main.zig",
            .workers => "examples/guestbook/src/worker.zig",
        },
        .bench => "examples/bench/src/main.zig",
        .tasks => "examples/tasks/src/main.zig",
    };
    const example_name = switch (example) {
        .chat => if (backend == .workers) "chat_worker" else "chat",
        .mobus => if (backend == .workers) "mobus_worker" else "mobus",
        .guestbook => if (backend == .workers) "guestbook_worker" else "guestbook",
        .bench => "bench",
        .tasks => "tasks",
    };

    const exe = b.addExecutable(.{
        .name = example_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(example_root),
            .target = target,
            .optimize = if (backend == .workers) .ReleaseSmall else optimize,
            .imports = &.{.{ .name = "akamata", .module = am_mod }},
        }),
    });

    if (backend == .workers) {
        exe.entry = .disabled;
        exe.rdynamic = true;
    }
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "run the selected example (native)").dependOn(&run.step);

    // === akamata-cli ===
    const cli_module = b.createModule(.{
        .root_source_file = b.path("tools/akamata/src/main.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    cli_module.link_libc = true;
    const cli_exe = b.addExecutable(.{
        .name = "akamata",
        .root_module = cli_module,
    });
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    b.step("cli", "build the akamata CLI binary").dependOn(&install_cli.step);

    // === Tests ===
    const test_step = b.step("test", "run unit tests");
    const test_targets = [_][]const u8{
        "tests/http_parser_test.zig",
        "tests/ws_frame_test.zig",
        "tests/router_test.zig",
        "tests/middleware_test.zig",
        "tests/db_sqlite_test.zig",
        "tests/d1_mock_test.zig",
        "tests/jwt_test.zig",
        "tests/bcrypt_test.zig",
        "tests/mq_test.zig",
        "tests/mobus_route_test.zig",
        "tests/app_test.zig",
        "tests/db_factory_test.zig",
        "tests/model_schema_test.zig",
        "tests/model_internal_test.zig",
        "tests/openapi_test.zig",
        "tests/testing_client_test.zig",
        "tests/negotiate_test.zig",
        "tests/etag_test.zig",
        "tests/client_gen_test.zig",
        "tests/jobs_test.zig",
    };

    const integration_step = b.step("integration", "build integration test (manual run)");
    const integration_targets = [_][]const u8{
        "tests/integration_http_test.zig",
    };

    // Tests for the `tasks` example. Compiled / run with `zig build tasks-test`.
    // Kept separate from the main suite so we don't pollute it with example-
    // specific paths, and so the example can be removed cleanly if needed.
    const tasks_test_step = b.step("tasks-test", "run tests for examples/tasks");

    if (backend == .native) {
        inline for (test_targets) |tf| {
            const t_mod = b.createModule(.{
                .root_source_file = b.path(tf),
                .target = native_target,
                .optimize = optimize,
                .imports = &.{.{ .name = "akamata", .module = am_mod }},
            });
            const t = b.addTest(.{ .root_module = t_mod });
            test_step.dependOn(&b.addRunArtifact(t).step);
        }
        // CLI tests (parsing wrangler.toml, UUID extraction)
        const cli_test_mod = b.createModule(.{
            .root_source_file = b.path("tools/akamata/src/main.zig"),
            .target = native_target,
            .optimize = optimize,
        });
        cli_test_mod.link_libc = true;
        const cli_t = b.addTest(.{ .root_module = cli_test_mod });
        test_step.dependOn(&b.addRunArtifact(cli_t).step);

        inline for (integration_targets) |tf| {
            const t_mod = b.createModule(.{
                .root_source_file = b.path(tf),
                .target = native_target,
                .optimize = optimize,
                .imports = &.{.{ .name = "akamata", .module = am_mod }},
            });
            const t = b.addTest(.{ .root_module = t_mod });
            integration_step.dependOn(&b.addRunArtifact(t).step);
        }

        // tasks example tests live alongside the example source so relative
        // `@import("app.zig")` resolves inside the module's source tree.
        const tasks_test_mod = b.createModule(.{
            .root_source_file = b.path("examples/tasks/src/integration_test.zig"),
            .target = native_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "akamata", .module = am_mod }},
        });
        const tasks_test = b.addTest(.{ .root_module = tasks_test_mod });
        tasks_test_step.dependOn(&b.addRunArtifact(tasks_test).step);
    }
}
