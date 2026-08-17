// akamata — command-line companion for the Akamata framework.
//
// Subcommands:
//   akamata init <name> [--target=native|workers|containers|both]
//   akamata build [--workers|--containers]
//   akamata dev
//   akamata deploy [--workers|--containers] [--config=PATH] [--migrate=SQL]
//   akamata db <sql-file> [--local|--remote] [--config=PATH]
//
// `akamata deploy --workers --migrate=schema.sql` is the one-shot path:
// auto-provisions the D1 database if the wrangler.toml database_id is still
// the placeholder, applies the migration to the remote D1, builds wasm, and
// runs `wrangler deploy`.

const std = @import("std");
const builtin = @import("builtin");
const api_client = @import("api_client.zig");
const client_tui = @import("client_tui.zig");

const tmpl_build_zig = @embedFile("templates/build.zig.tpl");
const tmpl_build_zon = @embedFile("templates/build.zig.zon.tpl");
const tmpl_main = @embedFile("templates/main.zig.tpl");
const tmpl_worker = @embedFile("templates/worker.zig.tpl");
const tmpl_gitignore = @embedFile("templates/.gitignore.tpl");
const tmpl_readme = @embedFile("templates/README.md.tpl");
const tmpl_wrangler = @embedFile("templates/wrangler.toml.tpl");
const tmpl_worker_index = @embedFile("templates/worker_index.mjs.tpl");
const tmpl_dockerfile = @embedFile("templates/Dockerfile.tpl");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());

    if (args.len < 2) {
        try usage();
        return;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help")) {
        if (args.len >= 3) try commandUsage(std.mem.sliceTo(args[2], 0)) else try usage();
        return;
    }
    if (args.len >= 3 and isHelpArg(std.mem.sliceTo(args[2], 0))) {
        try commandUsage(cmd);
        return;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "build")) {
        try cmdBuild(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "dev")) {
        try cmdDev(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "deploy")) {
        try cmdDeploy(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "sync-glue")) {
        try cmdSyncGlue(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "db")) {
        try cmdDb(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "migrate")) {
        try cmdMigrate(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "check")) {
        try cmdCheck(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "inspect")) {
        try cmdInspect(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "routes")) {
        try cmdRoutes(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        try cmdDoctor(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "config")) {
        try cmdConfig(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "test")) {
        try cmdTest(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "runner")) {
        try cmdRunner(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "generate")) {
        try cmdGenerate(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "destroy")) {
        try cmdDestroy(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "api")) {
        try cmdApi(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "client")) {
        const client_args = args[2..];
        const use_tui = client_args.len == 0 or std.mem.eql(u8, std.mem.sliceTo(client_args[0], 0), "--tui");
        (if (use_tui) client_tui.run(alloc, client_args) else api_client.run(alloc, client_args)) catch |err| {
            std.debug.print("akamata client: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try usage();
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "version")) {
        std.debug.print("akamata {s}\n", .{VERSION});
    } else {
        std.debug.print("akamata: unknown subcommand `{s}`\n", .{cmd});
        if (suggestCommand(cmd)) |s| {
            std.debug.print("\nDid you mean `akamata {s}`?\n\n", .{s});
        } else {
            std.debug.print("\nRun `akamata help` for the full list.\n\n", .{});
        }
        std.process.exit(2);
    }
}

const VERSION = "0.0.2";

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

const known_commands = [_][]const u8{
    "init", "build", "dev", "deploy", "sync-glue", "db", "migrate", "check", "inspect", "routes", "doctor", "config", "test", "runner", "generate", "destroy", "api", "client", "help", "version",
};

/// Lightweight nearest-match — if the user typed something within 2 edits
/// of a known command, suggest it. Avoids pulling in a real Levenshtein
/// library for what's a developer-experience nicety.
fn suggestCommand(input: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 3; // require ≤ 2 edits to suggest
    for (known_commands) |cmd| {
        const d = editDistance(input, cmd);
        if (d < best_d) {
            best_d = d;
            best = cmd;
        }
    }
    return best;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    // Plain Wagner-Fischer with two rolling rows. O(len(a) * len(b)) time.
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > 64 or b.len > 64) return @max(a.len, b.len);
    var prev: [65]usize = undefined;
    var curr: [65]usize = undefined;
    var j: usize = 0;
    while (j <= b.len) : (j += 1) prev[j] = j;
    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        curr[0] = i;
        var k: usize = 1;
        while (k <= b.len) : (k += 1) {
            const cost: usize = if (a[i - 1] == b[k - 1]) 0 else 1;
            const ins = curr[k - 1] + 1;
            const del = prev[k] + 1;
            const sub = prev[k - 1] + cost;
            curr[k] = @min(@min(ins, del), sub);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

fn usage() !void {
    const msg =
        \\Usage: akamata <command> [args]
        \\Version: akamata 0.0.2 (use `akamata --version` for the version)
        \\
        \\Commands:
        \\  init <name> [--target=native|workers|containers|both]
        \\      Scaffold a new Akamata app.
        \\  build [--workers|--containers] [--optimize=MODE]
        \\      Build the current app (native by default).
        \\  dev [--no-watch]
        \\      Run the app natively with hot reload: watches ./src (and
        \\      build.zig, .env), rebuilds and restarts on change. Ctrl-C to
        \\      stop. --no-watch does a one-shot `zig build run`.
        \\  deploy [--workers|--containers] [--config=PATH] [--migrate=SQL] [--optimize=MODE]
        \\      Build and deploy. For --workers:
        \\        * --config=PATH      wrangler.toml location
        \\                             (default: deploy/wrangler.toml, then wrangler.toml)
        \\        * --optimize=MODE    wasm optimize mode (default: ReleaseFast).
        \\                             ReleaseSmall for the smallest bundle.
        \\        * --migrate=SQL      apply the SQL file to the remote D1 before deploy.
        \\                             If the D1 in wrangler.toml has the placeholder
        \\                             database_id, it is auto-created and the ID is
        \\                             written back into the config.
        \\  sync-glue [--config=PATH] [--force]
        \\      Regenerate deploy/worker/index.mjs from the CLI's bundled
        \\      template. Run this after upgrading akamata so the JS host glue
        \\      matches the framework's current wasm ABI (a stale glue can fail
        \\      to instantiate, e.g. a missing import). Refuses to overwrite a
        \\      locally-modified glue unless --force is given.
        \\  db <sql-file> [--local|--remote] [--config=PATH]
        \\      Run a SQL migration against the D1 binding `DB`.
        \\  migrate generate <name> [--dir=migrations]
        \\      Create a new migration file `<timestamp>_<name>.sql` in
        \\      <dir> (default: ./migrations).
        \\  migrate up [--dir=migrations] [--target=VERSION]
        \\      Apply all pending migrations against the active database.
        \\      Reads DATABASE_URL from env/.env (same as your app). Records
        \\      each applied version in the `schema_migrations` table.
        \\  check [--quick]
        \\      Validate project structure and run the full test suite.
        \\  inspect [--json]
        \\      Print targets, migrations, environment, and project health.
        \\  routes [--json]
        \\      Print the application's OpenAPI route graph.
        \\  doctor [--json]
        \\      Diagnose the local project and deployment toolchain.
        \\  config <show|check>
        \\      Inspect configuration keys without exposing secret values.
        \\  test [--watch]
        \\      Run the application test suite once or continuously.
        \\  runner <command> [args]
        \\      Execute an application-defined typed management command.
        \\  generate resource <name> [field:type ...] [--pretend]
        \\      Generate a typed model/handler/test plus SQL migration.
        \\  destroy resource <name> [--force]
        \\      Remove files previously created by the resource generator.
        \\  api diff <before.json> <after.json>
        \\      Detect removed OpenAPI paths and operations (non-zero on breakage).
        \\  client [--tui] | [METHOD] <path-or-url> [options]
        \\      Explore and call an Akamata API. No arguments opens the TUI.
        \\  api call <operation-id> [options]
        \\      Resolve an operation from /openapi.json and call it.
        \\
    ;
    std.debug.print("{s}", .{msg});
}

fn commandUsage(command: []const u8) !void {
    const msg = if (std.mem.eql(u8, command, "init"))
        \\Usage: akamata init <name> [options]
        \\
        \\Scaffold a new Akamata application.
        \\
        \\Options:
        \\  --target=native|workers|containers|both  Generated deployment targets (default: native)
        \\  -h, --help                               Show this help
        \\
    else if (std.mem.eql(u8, command, "build"))
        \\Usage: akamata build [options]
        \\
        \\Build the current application.
        \\
        \\Options:
        \\  --workers                 Build the Workers wasm target
        \\  --containers              Build a static Linux container target
        \\  --optimize=MODE           Zig optimize mode
        \\  -h, --help                Show this help
        \\
    else if (std.mem.eql(u8, command, "deploy"))
        \\Usage: akamata deploy [options]
        \\
        \\Build and deploy the current application.
        \\
        \\Options:
        \\  --workers                 Deploy to Cloudflare Workers (default)
        \\  --containers              Build the Cloudflare Containers image
        \\  --config=PATH             Wrangler config path
        \\  --migrate=SQL             Apply a SQL file to remote D1 before deploy
        \\  --optimize=MODE           Workers optimize mode
        \\  -h, --help                Show this help without deploying
        \\
    else if (std.mem.eql(u8, command, "db"))
        \\Usage: akamata db <sql-file> [options]
        \\
        \\Apply a SQL file to the configured D1 database.
        \\
        \\Options:
        \\  --local                   Apply to local D1 (default)
        \\  --remote                  Apply to remote D1
        \\  --config=PATH             Wrangler config path
        \\  -h, --help                Show this help
        \\
    else if (std.mem.eql(u8, command, "migrate"))
        \\Usage: akamata migrate <generate|up|status|plan|rollback|redo> [options]
        \\
        \\Commands:
        \\  generate <name>           Create a timestamped SQL migration
        \\  up                        Apply pending migrations through the generated app runner
        \\  status                    Show applied/pending state for every migration
        \\  plan                      Preview migrations that `up` would apply
        \\  rollback                  Revert the latest migration using its down section
        \\  redo                      Roll back and reapply the latest migration
        \\
        \\Options:
        \\  --dir=PATH                Migration directory (default: migrations)
        \\  --target=VERSION          Stop after VERSION when applying
        \\  -h, --help                Show this help
        \\
    else if (std.mem.eql(u8, command, "check"))
        \\Usage: akamata check [--quick]
        \\Validate build files and source layout; without --quick also run `zig build test`.
        \\
    else if (std.mem.eql(u8, command, "inspect"))
        \\Usage: akamata inspect [--json]
        \\Show a deterministic project summary suitable for humans or tooling.
        \\
    else if (std.mem.eql(u8, command, "routes"))
        \\Usage: akamata routes [--json]
        \\       akamata routes explain METHOD /path
        \\Inspect routes, effective middleware, and endpoint budgets.
        \\
    else if (std.mem.eql(u8, command, "doctor"))
        \\Usage: akamata doctor [--json]
        \\Check project manifests, entry point, deployment files, and migrations.
        \\
    else if (std.mem.eql(u8, command, "config"))
        \\Usage: akamata config <show|check>
        \\Print configuration keys and presence without revealing values.
        \\
    else if (std.mem.eql(u8, command, "test"))
        \\Usage: akamata test [--watch]
        \\Run `zig build test`, optionally in watch mode.
        \\
    else if (std.mem.eql(u8, command, "runner"))
        \\Usage: akamata runner <command> [args]
        \\Delegate to the application's typed management-command runner.
        \\
    else if (std.mem.eql(u8, command, "generate") or std.mem.eql(u8, command, "destroy"))
        \\Usage: akamata generate resource <name> [field:type ...] [--pretend]
        \\       akamata destroy resource <name> [--force]
        \\
    else if (std.mem.eql(u8, command, "api"))
        \\Usage: akamata api diff <before.json> <after.json>
        \\       akamata api call <operation-id> [client options] [--spec=PATH]
        \\Diff reports removed paths and operations. Call resolves method/path from OpenAPI.
        \\
    else if (std.mem.eql(u8, command, "client"))
        \\Usage: akamata client [--tui] [--base-url=URL]
        \\       akamata client [METHOD] <path-or-url> [options]
        \\
        \\With no request arguments, opens the full-screen endpoint explorer.
        \\Routes are inspected from the application runner without exposing an HTTP route.
        \\
        \\Options:
        \\  --base-url=URL           Base for relative paths (default: http://127.0.0.1:8080)
        \\  --header=NAME:VALUE      Add a request header (repeatable; -H= is an alias)
        \\  --bearer=TOKEN           Add an Authorization Bearer header
        \\  --query=NAME=VALUE       Add a percent-encoded query parameter (repeatable)
        \\  --param=NAME=VALUE       Fill an OpenAPI {path} parameter for `api call`
        \\  --json=JSON              JSON body and content-type (validated before sending)
        \\                           Prefix with @ to read JSON from a file
        \\  --data=TEXT              Raw request body; @PATH reads from a file
        \\  --include                Print status and response headers
        \\  --raw                    Do not pretty-print JSON responses
        \\  --fail                   Return non-zero for HTTP 4xx/5xx
        \\  --max-bytes=N            Response limit (default: 4 MiB; maximum: 64 MiB)
        \\
    else {
        std.debug.print("akamata: unknown help topic `{s}`\n\n", .{command});
        try usage();
        return;
    };
    std.debug.print("{s}", .{msg});
}

// ---- init ----

const InitOpts = struct {
    name: []const u8,
    target: enum { native, workers, containers, both } = .native,
};

fn cmdInit(parent_alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) {
        std.debug.print("init: missing app name\n", .{});
        return error.UsageError;
    }
    var arena_state: std.heap.ArenaAllocator = .init(parent_alloc);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var opts: InitOpts = .{ .name = std.mem.sliceTo(args[0], 0) };
    if (!validAppName(opts.name)) {
        std.debug.print("init: app name must contain only ASCII letters, digits, '-' or '_'\n", .{});
        return error.UsageError;
    }
    for (args[1..]) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, a, "--target=")) {
            const v = a[9..];
            if (std.mem.eql(u8, v, "native")) opts.target = .native else if (std.mem.eql(u8, v, "workers")) opts.target = .workers else if (std.mem.eql(u8, v, "containers")) opts.target = .containers else if (std.mem.eql(u8, v, "both")) opts.target = .both else {
                std.debug.print("unknown --target value: {s}\n", .{v});
                return error.UsageError;
            }
        }
    }

    // 1. Create directory `name`
    try makeDirRecursive(opts.name);
    try makeDirRecursive(try std.fmt.allocPrint(alloc, "{s}/src", .{opts.name}));

    // 2. Write files
    try renderFile(alloc, opts.name, "build.zig", tmpl_build_zig, &.{
        .{ .key = "{{NAME}}", .val = opts.name },
    });
    const package_name = try alloc.dupe(u8, opts.name);
    for (package_name) |*c| if (c.* == '-') {
        c.* = '_';
    };
    const fingerprint_str = try std.fmt.allocPrint(alloc, "0x{x:0>16}", .{computeFingerprint(package_name)});
    defer alloc.free(fingerprint_str);
    try renderFile(alloc, opts.name, "build.zig.zon", tmpl_build_zon, &.{
        .{ .key = "{{NAME}}", .val = opts.name },
        .{ .key = "{{NAME_ENUM}}", .val = package_name },
        .{ .key = "{{FINGERPRINT}}", .val = fingerprint_str },
    });
    try renderFile(alloc, opts.name, "src/main.zig", tmpl_main, &.{
        .{ .key = "{{NAME}}", .val = opts.name },
    });
    try renderFile(alloc, opts.name, ".gitignore", tmpl_gitignore, &.{});
    try renderFile(alloc, opts.name, "README.md", tmpl_readme, &.{
        .{ .key = "{{NAME}}", .val = opts.name },
    });

    if (opts.target == .workers or opts.target == .both) {
        try renderFile(alloc, opts.name, "src/worker.zig", tmpl_worker, &.{
            .{ .key = "{{NAME}}", .val = opts.name },
        });
        try makeDirRecursive(try std.fmt.allocPrint(alloc, "{s}/deploy/worker", .{opts.name}));
        try renderFile(alloc, opts.name, "deploy/wrangler.toml", tmpl_wrangler, &.{
            .{ .key = "{{NAME}}", .val = opts.name },
        });
        try renderFile(alloc, opts.name, "deploy/worker/index.mjs", tmpl_worker_index, &.{
            .{ .key = "{{NAME}}", .val = opts.name },
        });
    }
    if (opts.target == .containers or opts.target == .both) {
        try makeDirRecursive(try std.fmt.allocPrint(alloc, "{s}/deploy", .{opts.name}));
        try renderFile(alloc, opts.name, "deploy/Dockerfile", tmpl_dockerfile, &.{
            .{ .key = "{{NAME}}", .val = opts.name },
        });
    }
    try makeDirRecursive(try std.fmt.allocPrint(alloc, "{s}/migrations", .{opts.name}));
    try renderFile(alloc, opts.name, "migrations/.gitkeep", "", &.{});

    std.debug.print(
        \\
        \\Created {s}/
        \\
        \\Next steps:
        \\  cd {s}
        \\  zig build run           # native dev server
        \\
    , .{ opts.name, opts.name });
}

fn validAppName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

/// Zig package fingerprint: lower 32 bits = CRC32 of the package name,
/// upper 32 bits = random. The compiler rejects the all-zero / placeholder
/// patterns, so each generated project needs a unique value.
fn computeFingerprint(name: []const u8) u64 {
    // Zig 0.16 layout: upper 32 bits = CRC32 of the package name (so the
    // compiler can detect a renamed package), lower 32 bits = an `id` that
    // just needs to avoid the placeholder/all-ones patterns the compiler
    // rejects. Deriving `id` from the name keeps fingerprints stable across
    // re-runs of `akamata init` for the same project.
    const name_hash: u32 = std.hash.Crc32.hash(name);
    var id: u32 = name_hash *% 0x9E37_79B1 ^ 0xC0FF_EE13;
    if (id == 0 or id == 0xFFFF_FFFF) id = 0x1234_5678;
    return (@as(u64, name_hash) << 32) | @as(u64, id);
}

const Replacement = struct { key: []const u8, val: []const u8 };

fn renderFile(
    alloc: std.mem.Allocator,
    root: []const u8,
    rel: []const u8,
    content: []const u8,
    replacements: []const Replacement,
) !void {
    var rendered: []u8 = try alloc.dupe(u8, content);
    for (replacements) |rep| {
        const next = try std.mem.replaceOwned(u8, alloc, rendered, rep.key, rep.val);
        alloc.free(rendered);
        rendered = next;
    }
    defer alloc.free(rendered);

    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, rel });
    defer alloc.free(path);
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);

    const FILE = opaque {};
    const Lib = struct {
        extern "c" fn fopen(p: [*:0]const u8, m: [*:0]const u8) ?*FILE;
        extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, s: *FILE) usize;
        extern "c" fn fclose(s: *FILE) c_int;
    };
    const f = Lib.fopen(path_z.ptr, "wb") orelse {
        std.debug.print("failed to create {s}\n", .{path});
        return error.WriteFailed;
    };
    defer _ = Lib.fclose(f);
    _ = Lib.fwrite(rendered.ptr, 1, rendered.len, f);
}

fn makeDirRecursive(path: []const u8) !void {
    // libc mkdir, multi-segment.
    const Lib = struct {
        extern "c" fn mkdir(p: [*:0]const u8, mode: u32) c_int;
    };
    var alloc_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer alloc_state.deinit();
    const a = alloc_state.allocator();

    var cur: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (cur.items.len > 0) try cur.append(a, '/');
        try cur.appendSlice(a, seg);
        const z = try a.dupeZ(u8, cur.items);
        _ = Lib.mkdir(z.ptr, 0o755);
    }
}

// ---- build ----

// Workers default optimize mode. ReleaseFast: the CPU-bound request paths
// (JSON, HTML inlining, validation) are noticeably faster than ReleaseSmall,
// and the wasm still gzips well under Cloudflare's bundle limit. Override per
// invocation with `--optimize=ReleaseSmall` (or `=ReleaseSafe`/`=Debug`).
const workers_default_optimize = "ReleaseFast";

/// Pull an explicit `--optimize=<Mode>` out of args, else return the default.
/// Recognises the Zig mode names; anything else is passed through verbatim so
/// `zig build` reports the error.
fn optimizeFlag(args: []const [:0]const u8, default_mode: []const u8) []const u8 {
    for (args) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, a, "--optimize=")) return a["--optimize=".len..];
    }
    return default_mode;
}

fn cmdBuild(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    var optimize_arg: ?[]u8 = null;
    defer if (optimize_arg) |value| alloc.free(value);
    try argv.append(alloc, "zig");
    try argv.append(alloc, "build");
    for (args) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, a, "--workers")) {
            try argv.append(alloc, "-Dbackend=workers");
            optimize_arg = try std.fmt.allocPrint(alloc, "-Doptimize={s}", .{optimizeFlag(args, workers_default_optimize)});
            try argv.append(alloc, optimize_arg.?);
        } else if (std.mem.eql(u8, a, "--containers")) {
            try argv.append(alloc, "-Dtarget=x86_64-linux-musl");
            try argv.append(alloc, "-Doptimize=ReleaseFast");
        }
    }
    try runChild(alloc, argv.items, null);
}

// ---- dev (hot reload) ----
//
// `akamata dev` builds the app, runs the native binary, and watches the source
// tree. On any change it rebuilds and restarts the binary. A `--no-watch` flag
// falls back to the old one-shot `zig build run`.
//
// Restart model: we run the built binary directly (not `zig build run`) so we
// own the PID and SIGTERM reaches the app — Akamata's serve() installs a
// SIGTERM handler that shuts the listener down cleanly, freeing the port for
// the next spawn. Change detection is mtime polling (portable, no inotify/
// kqueue); the poll interval is short enough to feel instant.

const dev_poll_ms = 400;

fn cmdDev(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var watch = true;
    for (args) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, a, "--no-watch")) watch = false;
    }
    if (!watch) {
        try runChild(alloc, &.{ "zig", "build", "run" }, null);
        return;
    }

    const bin = (try readZonName(alloc)) orelse {
        std.debug.print("dev: couldn't read .name from build.zig.zon; falling back to `zig build run`.\n", .{});
        try runChild(alloc, &.{ "zig", "build", "run" }, null);
        return;
    };
    defer alloc.free(bin);
    const bin_path = try std.fmt.allocPrint(alloc, "zig-out/bin/{s}", .{bin});
    defer alloc.free(bin_path);
    const bin_path_z = try alloc.dupeZ(u8, bin_path);
    defer alloc.free(bin_path_z);

    std.debug.print("==> akamata dev: watching ./src, ./migrations, build files, and .env ({d} migration(s)). Ctrl-C to stop.\n", .{countSqlMigrations("migrations")});
    dev_install_sigint();

    // The app runs in its own process group; `child` is the leader pid (-1 when
    // none). The loop is single-threaded and the signal handler only flips
    // dev_running, so a plain local is safe. `defer` guarantees teardown even on
    // Ctrl-C mid-build.
    var child: c_int = -1;
    defer stopChild(child);

    var sig = watchSignature(alloc);
    var first = true;

    while (dev_running.load(.seq_cst)) {
        if (first or watchSignature(alloc) != sig) {
            first = false;
            sig = watchSignature(alloc);

            if (child > 0) {
                std.debug.print("==> akamata dev: change detected — restarting\n", .{});
                stopChild(child);
                child = -1;
            }

            std.debug.print("==> akamata dev: building\n", .{});
            if (runChild(alloc, &.{ "zig", "build" }, null)) |_| {
                // A build can be interrupted by Ctrl-C; bail before spawning.
                if (!dev_running.load(.seq_cst)) break;
                // Re-read the signature AFTER the build: the build can touch
                // files (and takes time), so we don't want its own writes to
                // immediately re-trigger. Then spawn the freshly built binary.
                sig = watchSignature(alloc);
                child = spawnBinary(bin_path_z.ptr);
                if (child <= 0) std.debug.print("dev: failed to spawn {s}\n", .{bin_path});
            } else |_| {
                if (!dev_running.load(.seq_cst)) break;
                std.debug.print("==> akamata dev: build failed — fix and save to retry\n", .{});
            }
        }

        // Reap an app that exited on its own (e.g. crash) so we don't leave a
        // zombie; report it but keep watching so the next save restarts it.
        if (child > 0) {
            var status: c_int = 0;
            if (waitpid(child, &status, WNOHANG) == child) {
                std.debug.print("==> akamata dev: app exited (status {d}) — waiting for next change\n", .{status});
                child = -1;
            }
        }

        sleepMs(dev_poll_ms);
    }

    std.debug.print("\n==> akamata dev: stopping\n", .{});
}

/// Read `.name = .<ident>,` from build.zig.zon. Zig requires the package name
/// to be an enum literal, so we read the bareword after `.name = .`.
fn readZonName(alloc: std.mem.Allocator) !?[]const u8 {
    const content = readFileAlloc(alloc, "build.zig.zon", 1 * 1024 * 1024) catch return null;
    defer alloc.free(content);
    const key = ".name";
    const ki = std.mem.indexOf(u8, content, key) orelse return null;
    var i = ki + key.len;
    // skip spaces, '=', spaces, then the leading '.' of the enum literal
    while (i < content.len and (content[i] == ' ' or content[i] == '\t' or content[i] == '=')) i += 1;
    if (i >= content.len or content[i] != '.') return null;
    i += 1;
    const start = i;
    while (i < content.len and (std.ascii.isAlphanumeric(content[i]) or content[i] == '_')) i += 1;
    if (i == start) return null;
    return try alloc.dupe(u8, content[start..i]);
}

/// Spawn `path` as a child process, returning its pid (or -1 on failure).
/// Spawn `path` in its OWN process group (the child calls setpgid(0,0), so its
/// pgid == its pid). Two reasons:
///   1. A terminal Ctrl-C delivers SIGINT to the foreground *process group* —
///      i.e. to `akamata dev`. We do NOT want it delivered straight to the app
///      too (that races with our managed shutdown and can orphan the app if dev
///      exits first). Putting the app in its own group isolates it; dev is the
///      sole owner of the app's lifecycle.
///   2. Killing the group (`killpg`) takes down the app AND anything it spawned.
/// Returns the child pid (== its pgid), or -1 on fork failure.
fn spawnBinary(path: [*:0]const u8) c_int {
    const pid = fork();
    if (pid == 0) {
        _ = setpgid(0, 0); // become leader of a new process group
        const argv = [_:null]?[*:0]const u8{path};
        _ = execvp(path, &argv);
        _exit(127); // execvp only returns on failure
    }
    if (pid > 0) _ = setpgid(pid, pid); // also set from parent to avoid the race
    return pid;
}

/// Stop the app process group: SIGTERM (graceful — Akamata's serve() catches it
/// and drains the accept loop), then a short grace period, then SIGKILL if it's
/// still alive. `pid` is the group leader (== pgid). Reaps the leader.
fn stopChild(pid: c_int) void {
    if (pid <= 0) return;
    _ = killpg(pid, SIGTERM);
    // Wait up to ~2s for graceful exit, polling so we don't hang on a wedged app.
    var waited_ms: u64 = 0;
    while (waited_ms < 2000) {
        var status: c_int = 0;
        if (waitpid(pid, &status, WNOHANG) == pid) return; // reaped
        sleepMs(50);
        waited_ms += 50;
    }
    _ = killpg(pid, SIGKILL);
    _ = waitpid(pid, null, 0);
}

/// A coarse change signature over the watched files: every regular file under
/// ./src plus a few top-level files. We fold each file's mtime (sec, nsec) into
/// a running hash; any add/remove/modify changes the result. Missing files are
/// skipped. O(files) per poll, which is fine for a source tree.
fn watchSignature(alloc: std.mem.Allocator) u64 {
    var h: u64 = 1469598103934665603; // FNV-1a offset basis
    walkMtimes("src", &h);
    walkMtimes("migrations", &h);
    for ([_][]const u8{ "build.zig", "build.zig.zon", ".env" }) |f| {
        var st: stat_t = undefined;
        const fz = alloc.dupeZ(u8, f) catch continue;
        defer alloc.free(fz);
        if (stat(fz.ptr, &st) == 0) foldMtime(&h, st.mtim);
    }
    return h;
}

fn foldMtime(h: *u64, ts: Timespec) void {
    const v: u64 = (@as(u64, @bitCast(@as(i64, ts.sec))) *% 1_000_000_000) +% @as(u64, @bitCast(@as(i64, ts.nsec)));
    h.* = (h.* ^ v) *% 1099511628211; // FNV-1a prime
}

/// Recursively fold mtimes of regular files under `dir` into `h`. Uses a fixed
/// path buffer; paths longer than the buffer are skipped (won't happen for a
/// normal source tree).
fn walkMtimes(dir: []const u8, h: *u64) void {
    var dir_buf: [4096]u8 = undefined;
    if (dir.len + 1 > dir_buf.len) return;
    @memcpy(dir_buf[0..dir.len], dir);
    dir_buf[dir.len] = 0;
    const d = opendir(@ptrCast(&dir_buf)) orelse return;
    defer _ = closedir(d);
    while (readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (name.len == 0 or name[0] == '.') continue; // skip ., .., dotfiles
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (ent.type == DT_DIR) {
            walkMtimes(path, h);
        } else if (ent.type == DT_REG) {
            var st: stat_t = undefined;
            if (stat(path.ptr, &st) == 0) foldMtime(h, st.mtim);
        }
    }
}

// ---- deploy ----

const PLACEHOLDER_UUID = "00000000-0000-0000-0000-000000000000";

fn cmdDeploy(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var target_workers = false;
    var target_containers = false;
    var config_path: ?[]const u8 = null;
    var migrate_path: ?[]const u8 = null;
    for (args) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, a, "--workers")) target_workers = true else if (std.mem.eql(u8, a, "--containers")) target_containers = true else if (std.mem.startsWith(u8, a, "--config=")) config_path = a[9..] else if (std.mem.startsWith(u8, a, "--migrate=")) migrate_path = a[10..];
    }
    if (!target_workers and !target_containers) target_workers = true;

    if (target_workers) {
        const cfg = config_path orelse defaultConfigPath() orelse {
            std.debug.print("deploy: no wrangler.toml found at deploy/wrangler.toml or ./wrangler.toml. Pass --config=PATH.\n", .{});
            return error.UsageError;
        };
        // 1. Ensure the D1 referenced by the config exists, auto-creating if
        //    the database_id is still the placeholder UUID.
        try ensureD1Provisioned(alloc, cfg);
        // 2. Apply the migration SQL to the remote D1, if requested.
        if (migrate_path) |sql| {
            const db_name = (try readD1FromConfig(alloc, cfg)) orelse {
                std.debug.print("--migrate given but {s} has no [[d1_databases]] entry — nothing to migrate against.\n", .{cfg});
                return error.UsageError;
            };
            std.debug.print("==> akamata: applying {s} to remote D1 \"{s}\"\n", .{ sql, db_name.name });
            try runChild(alloc, &.{ "npx", "wrangler", "d1", "execute", db_name.name, "--remote", "--config", cfg, "--file", sql, "--yes" }, null);
            alloc.free(db_name.name);
            alloc.free(db_name.id);
            alloc.free(db_name.binding);
        }
        // 3. Build wasm + deploy.
        const opt = optimizeFlag(args, workers_default_optimize);
        std.debug.print("==> akamata: building wasm ({s})\n", .{opt});
        const opt_flag = try std.fmt.allocPrint(alloc, "-Doptimize={s}", .{opt});
        defer alloc.free(opt_flag);
        try runChild(alloc, &.{ "zig", "build", "-Dbackend=workers", opt_flag }, null);
        std.debug.print("==> akamata: wrangler deploy\n", .{});
        try runChild(alloc, &.{ "npx", "wrangler", "deploy", "--config", cfg }, null);
    }
    if (target_containers) {
        try runChild(alloc, &.{ "zig", "build", "-Dtarget=x86_64-linux-musl", "-Doptimize=ReleaseFast" }, null);
        try runChild(alloc, &.{ "docker", "build", "-f", "deploy/Dockerfile", "-t", "akamata-app", "." }, null);
    }
}

// ---- sync-glue ----

/// Regenerate `<config-dir>/worker/index.mjs` from the bundled template so the
/// JS host glue tracks the framework's current wasm ABI. The glue is generated
/// (not hand-authored) — the only project-specific value is `{{NAME}}` (the
/// wasm artifact name), read from the wrangler.toml top-level `name`.
fn cmdSyncGlue(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var config_path: ?[]const u8 = null;
    var force = false;
    for (args) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, a, "--config=")) config_path = a[9..] else if (std.mem.eql(u8, a, "--force")) force = true;
    }

    const cfg = config_path orelse defaultConfigPath() orelse {
        std.debug.print("sync-glue: no wrangler.toml found at deploy/wrangler.toml or ./wrangler.toml. Pass --config=PATH.\n", .{});
        return error.UsageError;
    };

    const name = (try readWranglerName(alloc, cfg)) orelse {
        std.debug.print("sync-glue: {s} has no top-level `name = \"...\"`; can't resolve the wasm artifact name.\n", .{cfg});
        return error.UsageError;
    };
    defer alloc.free(name);

    // The glue lives in a sibling `worker/` dir next to the config.
    const dir = dirName(cfg); // e.g. "deploy" from "deploy/wrangler.toml", or "."
    const glue_path = try std.fmt.allocPrint(alloc, "{s}/worker/index.mjs", .{dir});
    defer alloc.free(glue_path);

    // Render the template with the project name.
    const rendered = try std.mem.replaceOwned(u8, alloc, tmpl_worker_index, "{{NAME}}", name);
    defer alloc.free(rendered);

    // No-op if unchanged.
    const existing: ?[]u8 = readFileAlloc(alloc, glue_path, 4 * 1024 * 1024) catch null;
    defer if (existing) |e| alloc.free(e);
    if (existing) |e| {
        if (std.mem.eql(u8, e, rendered)) {
            std.debug.print("sync-glue: {s} already up to date.\n", .{glue_path});
            return;
        }
        // The file diverges from the template. Back it up before overwriting,
        // unless the user opted out with --force.
        if (!force) {
            const bak = try std.fmt.allocPrint(alloc, "{s}.bak", .{glue_path});
            defer alloc.free(bak);
            try writeFileBytes(bak, e);
            std.debug.print("==> akamata: backed up existing glue to {s}\n", .{bak});
        }
    } else {
        try makeDirRecursive(try std.fmt.allocPrint(alloc, "{s}/worker", .{dir}));
    }

    try writeFileBytes(glue_path, rendered);
    std.debug.print("==> akamata: wrote {s} (name=\"{s}\")\n", .{ glue_path, name });
    std.debug.print("    Rebuild + redeploy so the wasm and glue ship together: akamata deploy --workers\n", .{});
}

/// Read the top-level `name = "..."` from a wrangler.toml (the key before any
/// `[section]`). Returns an owned copy, or null if absent.
fn readWranglerName(alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const content = try readFileAlloc(alloc, path, 1 * 1024 * 1024);
    defer alloc.free(content);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') break; // entered a section; top-level keys are done
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, k, "name")) continue;
        var v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
        return try alloc.dupe(u8, v);
    }
    return null;
}

/// Directory portion of a path (everything before the last '/'), or "." if the
/// path has no separator.
fn dirName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return ".";
}

fn defaultConfigPath() ?[]const u8 {
    if (fileExists("deploy/wrangler.toml")) return "deploy/wrangler.toml";
    if (fileExists("wrangler.toml")) return "wrangler.toml";
    return null;
}

fn fileExists(path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const FILE = opaque {};
    const Lib = struct {
        extern "c" fn fopen(p: [*:0]const u8, m: [*:0]const u8) ?*FILE;
        extern "c" fn fclose(s: *FILE) c_int;
    };
    const f = Lib.fopen(@ptrCast(&buf), "rb") orelse return false;
    _ = Lib.fclose(f);
    return true;
}

const D1Info = struct {
    binding: []u8,
    name: []u8,
    id: []u8,
};

/// Parse the *first* `[[d1_databases]]` block in a wrangler.toml. Returns
/// null if none exists. Caller owns the strings (free with the same allocator).
/// Hand-rolled minimal TOML reader — wrangler files we generate are simple
/// enough that this stays robust.
fn readD1FromConfig(alloc: std.mem.Allocator, path: []const u8) !?D1Info {
    const content = try readFileAlloc(alloc, path, 1 * 1024 * 1024);
    defer alloc.free(content);

    var binding: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var in_block = false;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[d1_databases]]")) {
            if (in_block and binding != null and name != null and id != null) break;
            in_block = true;
            continue;
        }
        // A new section starts: stop collecting if we already had a complete one.
        if (line[0] == '[') {
            if (in_block and binding != null and name != null and id != null) break;
            in_block = false;
            continue;
        }
        if (!in_block) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        var v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // strip surrounding quotes
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) {
            v = v[1 .. v.len - 1];
        }
        if (std.mem.eql(u8, k, "binding")) binding = v else if (std.mem.eql(u8, k, "database_name")) name = v else if (std.mem.eql(u8, k, "database_id")) id = v;
    }
    if (binding == null or name == null or id == null) return null;
    return .{
        .binding = try alloc.dupe(u8, binding.?),
        .name = try alloc.dupe(u8, name.?),
        .id = try alloc.dupe(u8, id.?),
    };
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const path_z = try alloc.dupeZ(u8, path);
    defer alloc.free(path_z);
    const FILE = opaque {};
    const Lib = struct {
        extern "c" fn fopen(p: [*:0]const u8, m: [*:0]const u8) ?*FILE;
        extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, s: *FILE) usize;
        extern "c" fn fclose(s: *FILE) c_int;
        extern "c" fn fseek(s: *FILE, off: c_long, whence: c_int) c_int;
        extern "c" fn ftell(s: *FILE) c_long;
    };
    const f = Lib.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = Lib.fclose(f);
    _ = Lib.fseek(f, 0, 2); // SEEK_END
    const sz_signed = Lib.ftell(f);
    if (sz_signed < 0) return error.FileNotFound;
    const sz: usize = @intCast(sz_signed);
    if (sz > max_bytes) return error.FileTooLarge;
    _ = Lib.fseek(f, 0, 0);
    const buf = try alloc.alloc(u8, sz);
    const got = Lib.fread(buf.ptr, 1, sz, f);
    return buf[0..got];
}

fn writeFileBytes(path: []const u8, bytes: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const FILE = opaque {};
    const Lib = struct {
        extern "c" fn fopen(p: [*:0]const u8, m: [*:0]const u8) ?*FILE;
        extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, s: *FILE) usize;
        extern "c" fn fclose(s: *FILE) c_int;
    };
    const f = Lib.fopen(@ptrCast(&path_buf), "wb") orelse return error.WriteFailed;
    defer _ = Lib.fclose(f);
    _ = Lib.fwrite(bytes.ptr, 1, bytes.len, f);
}

/// If the config's D1 database_id is the placeholder UUID, create the DB and
/// write the real UUID back. If a D1 with that name already exists in the
/// account, adopt its UUID instead (so re-running deploy after a failure
/// halfway through is idempotent). No-op otherwise.
fn ensureD1Provisioned(alloc: std.mem.Allocator, cfg: []const u8) !void {
    const info = (try readD1FromConfig(alloc, cfg)) orelse return; // no D1 in this config
    defer {
        alloc.free(info.binding);
        alloc.free(info.name);
        alloc.free(info.id);
    }
    if (!std.mem.eql(u8, info.id, PLACEHOLDER_UUID)) return;
    std.debug.print("==> akamata: provisioning D1 \"{s}\" (database_id is placeholder)\n", .{info.name});

    // Try `wrangler d1 create`. If it fails with "already exists", look it up
    // via `wrangler d1 list --json` and adopt that UUID.
    var resolved_uuid: ?[]const u8 = null;
    var owned_create_out: ?[]u8 = null;
    var owned_list_out: ?[]u8 = null;
    var owned_list_uuid: ?[]u8 = null;
    defer {
        if (owned_create_out) |b| alloc.free(b);
        if (owned_list_out) |b| alloc.free(b);
        if (owned_list_uuid) |b| alloc.free(b);
    }

    const create = try captureCmdAllowFail(alloc, &.{ "npx", "wrangler", "d1", "create", info.name });
    owned_create_out = create.stdout;
    if (create.rc == 0) {
        resolved_uuid = extractUuid(create.stdout);
    } else if (std.mem.indexOf(u8, create.stdout, "already exists") != null) {
        std.debug.print("==> akamata: D1 \"{s}\" already exists — looking up its UUID via `d1 list`\n", .{info.name});
        const listed = try captureCmdAllowFail(alloc, &.{ "npx", "wrangler", "d1", "list", "--json" });
        owned_list_out = listed.stdout;
        if (listed.rc != 0) {
            std.debug.print("wrangler d1 list failed (rc={d}):\n{s}\n", .{ listed.rc, listed.stdout });
            return error.ProvisionFailed;
        }
        if (try lookupD1UuidByName(alloc, listed.stdout, info.name)) |u| {
            owned_list_uuid = u;
            resolved_uuid = u;
        } else {
            std.debug.print("d1 list returned no matching name \"{s}\". Output:\n{s}\n", .{ info.name, listed.stdout });
        }
    } else {
        std.debug.print("wrangler d1 create failed (rc={d}):\n{s}\n", .{ create.rc, create.stdout });
        return error.ProvisionFailed;
    }

    const uuid = resolved_uuid orelse {
        std.debug.print("could not resolve database_id from wrangler output\n", .{});
        return error.ProvisionFailed;
    };
    std.debug.print("==> akamata: resolved D1 \"{s}\" (id={s})\n", .{ info.name, uuid });

    // Rewrite the config in place: replace the placeholder UUID with the real
    // one. We do a simple string replacement scoped to the file content.
    const old_content = try readFileAlloc(alloc, cfg, 1 * 1024 * 1024);
    defer alloc.free(old_content);
    const new_content = try std.mem.replaceOwned(u8, alloc, old_content, PLACEHOLDER_UUID, uuid);
    defer alloc.free(new_content);
    try writeFileBytes(cfg, new_content);
    std.debug.print("==> akamata: wrote new database_id back to {s}\n", .{cfg});
}

/// Parse the JSON array returned by `wrangler d1 list --json` and find the
/// `uuid` whose `name` matches. Returns owned memory (caller frees).
///
/// We search for the JSON payload by scanning for `[` that's followed (after
/// whitespace) by `{` or `]` — wrangler prefixes the JSON with a banner that
/// itself contains a `[fake-npx]` style bracket on some setups, so a naïve
/// `indexOfScalar(_, '[')` lands on the wrong bracket.
fn lookupD1UuidByName(alloc: std.mem.Allocator, json_bytes: []const u8, want_name: []const u8) !?[]u8 {
    const start = findJsonArrayStart(json_bytes) orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes[start..], .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const name_v = item.object.get("name") orelse continue;
        if (name_v != .string) continue;
        if (!std.mem.eql(u8, name_v.string, want_name)) continue;
        const uuid_v = item.object.get("uuid") orelse continue;
        if (uuid_v != .string) continue;
        return try alloc.dupe(u8, uuid_v.string);
    }
    return null;
}

/// Locate an opening `[` whose next non-whitespace char is `{` or `]` — i.e.
/// the start of a JSON array of objects (or an empty array). Returns the
/// index of the `[`, or null if none found.
fn findJsonArrayStart(text: []const u8) ?usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '[') continue;
        var j: usize = i + 1;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) : (j += 1) {}
        if (j < text.len and (text[j] == '{' or text[j] == ']')) return i;
    }
    return null;
}

/// Find a 36-char UUID in text (8-4-4-4-12 lowercase hex form).
fn extractUuid(text: []const u8) ?[]const u8 {
    if (text.len < 36) return null;
    var i: usize = 0;
    while (i + 36 <= text.len) : (i += 1) {
        const win = text[i .. i + 36];
        if (isUuid(win)) return win;
    }
    return null;
}

fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

test "suggestCommand: 'deplyo' -> 'deploy'" {
    const got = suggestCommand("deplyo") orelse return error.TestExpectedSuggestion;
    try std.testing.expectEqualStrings("deploy", got);
}

test "suggestCommand: 'migrtae' -> 'migrate'" {
    const got = suggestCommand("migrtae") orelse return error.TestExpectedSuggestion;
    try std.testing.expectEqualStrings("migrate", got);
}

test "suggestCommand: completely different input returns null" {
    try std.testing.expect(suggestCommand("xyz") == null);
}

test "help flags are recognized before command execution" {
    try std.testing.expect(isHelpArg("--help"));
    try std.testing.expect(isHelpArg("-h"));
    try std.testing.expect(!isHelpArg("--workers"));
}

test "scaffold names are path-safe and support hyphens" {
    try std.testing.expect(validAppName("release-smoke"));
    try std.testing.expect(validAppName("app_2"));
    try std.testing.expect(!validAppName("../escape"));
    try std.testing.expect(!validAppName("bad/name"));
    try std.testing.expect(!validAppName("2app"));
    try std.testing.expect(std.mem.indexOf(u8, tmpl_build_zon, ".name = .{{NAME_ENUM}}") != null);
}

test "scaffold dependency is remote, pinned, and locally overridable" {
    try std.testing.expect(std.mem.indexOf(u8, tmpl_build_zon, ".url = \"https://github.com/appleuser634/Akamata/archive/") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_build_zon, ".hash = \"akamata-") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_build_zon, "../Akamata") == null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_build_zon, "zig build --fork=") != null);
}

test "scaffold dependency tracks the current stable release" {
    try std.testing.expect(std.mem.indexOf(u8, tmpl_build_zon, "archive/refs/tags/v0.0.2.tar.gz") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_build_zon, "akamata-0.0.2-uJIoI5T_KAFZkcv0y51rjhWLE5gk1A6Nj82GUN-GDKu8") != null);
}

test "Workers scaffold guards zero-length wasm memory access" {
    try std.testing.expect(std.mem.indexOf(u8, tmpl_worker_index, "l === 0 ? new Uint8Array(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_worker_index, "if (b.length > 0) new Uint8Array(memory.buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_worker_index, "new Uint8Array(memory.buffer, p, l)") != null);
}

test "Workers scaffold includes current observability clock imports" {
    try std.testing.expect(std.mem.indexOf(u8, tmpl_worker_index, "akamata_monotonic_ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_worker_index, "performance.now()") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_worker_index, "akamata_unix_micros") != null);
}

test "generated app exposes the migration runner expected by the CLI" {
    try std.testing.expect(std.mem.indexOf(u8, tmpl_main, "\"migrate-up\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_main, "am.model.migrate.Migrator") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_main, "loadMigrationsFromDir") != null);
}

test "generated app exposes typed management runner protocol" {
    try std.testing.expect(std.mem.indexOf(u8, tmpl_main, "akamata-runner") != null);
    try std.testing.expect(std.mem.indexOf(u8, tmpl_main, "runnerCommand") != null);
}

test "generated migration comments do not contain statement separators" {
    var lines = std.mem.splitScalar(u8, migration_file_template, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "--")) {
            try std.testing.expect(std.mem.indexOfScalar(u8, line, ';') == null);
        }
    }
}

test "extractUuid finds the UUID in wrangler create output" {
    const sample =
        \\ ⛅️ wrangler 4.93.1
        \\Successfully created DB 'guestbook' in region APAC
        \\
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_name = "guestbook"
        \\database_id = "abcd1234-5678-9abc-def0-fedcba987654"
        \\
    ;
    const got = extractUuid(sample) orelse return error.TestUnexpectedNullUuid;
    try std.testing.expectEqualStrings("abcd1234-5678-9abc-def0-fedcba987654", got);
}

test "extractUuid rejects strings without a UUID" {
    try std.testing.expect(extractUuid("no uuid here") == null);
    // Almost — wrong hex length in last group
    try std.testing.expect(extractUuid("abcd1234-5678-9abc-def0-fedcba98765") == null);
}

test "isUuid: positive and negative cases" {
    try std.testing.expect(isUuid("00000000-0000-0000-0000-000000000000"));
    try std.testing.expect(isUuid("abcd1234-5678-9abc-def0-fedcba987654"));
    try std.testing.expect(!isUuid("abcd1234_5678_9abc_def0_fedcba987654")); // underscores
    try std.testing.expect(!isUuid("abcd1234-5678-9abc-def0-fedcba98765z")); // non-hex
    try std.testing.expect(!isUuid("short"));
}

test "readD1FromConfig: extracts first [[d1_databases]] block" {
    const path = "/tmp/akamata_test_wrangler.toml";
    // Write a fixture so the parser has something to read.
    const content =
        \\name = "guestbook"
        \\main = "worker/index.mjs"
        \\
        \\[vars]
        \\DATABASE_URL = "d1:DB"
        \\
        \\[[d1_databases]]
        \\binding = "DB"
        \\database_name = "guestbook"
        \\database_id = "00000000-0000-0000-0000-000000000000"
        \\
    ;
    try writeFileBytes(path, content);
    const info = (try readD1FromConfig(std.testing.allocator, path)) orelse return error.TestExpectedD1;
    defer {
        std.testing.allocator.free(info.binding);
        std.testing.allocator.free(info.name);
        std.testing.allocator.free(info.id);
    }
    try std.testing.expectEqualStrings("DB", info.binding);
    try std.testing.expectEqualStrings("guestbook", info.name);
    try std.testing.expectEqualStrings(PLACEHOLDER_UUID, info.id);
}

test "lookupD1UuidByName: skips bracketed banner text before the JSON" {
    // Reproduces the bug where the shim's `[fake-npx]` log got picked up as
    // the start of the JSON array. wrangler itself can also emit warnings
    // containing `[` before the actual payload.
    const sample =
        \\[fake-npx] wrangler d1 list --json
        \\ ⛅️ wrangler 4.93.1 (fake)
        \\[
        \\  {
        \\    "uuid": "19c8e27f-d6af-420e-9683-1cfff695c25e",
        \\    "name": "guestbook"
        \\  }
        \\]
    ;
    const got = (try lookupD1UuidByName(std.testing.allocator, sample, "guestbook")) orelse return error.TestExpectedUuid;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("19c8e27f-d6af-420e-9683-1cfff695c25e", got);
}

test "lookupD1UuidByName: finds the matching name in JSON array" {
    const sample =
        \\ ⛅️ wrangler 4.93.1
        \\[
        \\  {
        \\    "uuid": "19c8e27f-d6af-420e-9683-1cfff695c25e",
        \\    "name": "guestbook",
        \\    "created_at": "2026-05-22T13:02:13.001Z"
        \\  },
        \\  {
        \\    "uuid": "deadbeef-1234-5678-9abc-def012345678",
        \\    "name": "other"
        \\  }
        \\]
    ;
    const got = (try lookupD1UuidByName(std.testing.allocator, sample, "guestbook")) orelse return error.TestExpectedUuid;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("19c8e27f-d6af-420e-9683-1cfff695c25e", got);

    // Name not in the list → null
    const missing = try lookupD1UuidByName(std.testing.allocator, sample, "nonexistent");
    try std.testing.expect(missing == null);
}

test "readD1FromConfig: ignores commented-out blocks" {
    const path = "/tmp/akamata_test_wrangler_commented.toml";
    const content =
        \\name = "x"
        \\# [[d1_databases]]
        \\# binding = "DB"
        \\# database_name = "x"
        \\# database_id = "00000000-0000-0000-0000-000000000000"
        \\
        \\[vars]
        \\KEY = "v"
        \\
    ;
    try writeFileBytes(path, content);
    try std.testing.expect((try readD1FromConfig(std.testing.allocator, path)) == null);
}

const CapturedCmd = struct { rc: c_int, stdout: []u8 };

/// Run a command and return both its exit code and combined stdout/stderr.
/// Does NOT error on non-zero exit — caller inspects `rc` and decides.
fn captureCmdAllowFail(alloc: std.mem.Allocator, argv: []const []const u8) !CapturedCmd {
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(alloc);
    for (argv, 0..) |a, i| {
        if (i > 0) try cmd.append(alloc, ' ');
        try cmd.append(alloc, '\'');
        for (a) |ch| {
            if (ch == '\'') try cmd.appendSlice(alloc, "'\\''") else try cmd.append(alloc, ch);
        }
        try cmd.append(alloc, '\'');
    }
    try cmd.appendSlice(alloc, " 2>&1");
    try cmd.append(alloc, 0);

    const FILE = opaque {};
    const Lib = struct {
        extern "c" fn popen(c: [*:0]const u8, m: [*:0]const u8) ?*FILE;
        extern "c" fn pclose(s: *FILE) c_int;
        extern "c" fn fread(p: [*]u8, sz: usize, n: usize, s: *FILE) usize;
    };
    const cmd_z: [*:0]const u8 = @ptrCast(cmd.items.ptr);
    const f = Lib.popen(cmd_z, "r") orelse return error.PopenFailed;
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = Lib.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    const rc = Lib.pclose(f);
    return .{ .rc = rc, .stdout = try out.toOwnedSlice(alloc) };
}

/// Run a command and return its captured stdout. Errors out if the command
/// exits non-zero. Mirrors `runChild` but with popen() to read output.
fn captureCmd(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(alloc);
    for (argv, 0..) |a, i| {
        if (i > 0) try cmd.append(alloc, ' ');
        try cmd.append(alloc, '\'');
        for (a) |ch| {
            if (ch == '\'') try cmd.appendSlice(alloc, "'\\''") else try cmd.append(alloc, ch);
        }
        try cmd.append(alloc, '\'');
    }
    // Combine stderr into stdout so we don't miss the UUID if wrangler ever
    // writes its success line there.
    try cmd.appendSlice(alloc, " 2>&1");
    try cmd.append(alloc, 0);

    const FILE = opaque {};
    const Lib = struct {
        extern "c" fn popen(c: [*:0]const u8, m: [*:0]const u8) ?*FILE;
        extern "c" fn pclose(s: *FILE) c_int;
        extern "c" fn fread(p: [*]u8, sz: usize, n: usize, s: *FILE) usize;
    };
    const cmd_z: [*:0]const u8 = @ptrCast(cmd.items.ptr);
    const f = Lib.popen(cmd_z, "r") orelse return error.PopenFailed;
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = Lib.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    const rc = Lib.pclose(f);
    if (rc != 0) {
        std.debug.print("captureCmd: command failed (rc={d}):\n{s}\n", .{ rc, out.items });
        out.deinit(alloc);
        return error.ChildFailed;
    }
    return out.toOwnedSlice(alloc);
}

// ---- project intelligence / generators ----

fn cmdCheck(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var quick = false;
    for (args) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, arg, "--quick")) quick = true else return error.UsageError;
    }
    var failures: usize = 0;
    const required = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    for (required) |path| {
        const exists = fileExists(path) or directoryExists(path);
        std.debug.print("{s} {s}\n", .{ if (exists) "ok " else "ERR", path });
        if (!exists) failures += 1;
    }
    if (failures != 0) return error.ProjectCheckFailed;
    if (!quick) try runChild(alloc, &.{ "zig", "build", "test" }, null);
    std.debug.print("check: project is healthy\n", .{});
}

fn cmdInspect(_: std.mem.Allocator, args: []const [:0]const u8) !void {
    var json = false;
    for (args) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, arg, "--json")) json = true else return error.UsageError;
    }
    const native = fileExists("build.zig");
    const workers = fileExists("deploy/wrangler.toml") or fileExists("wrangler.toml");
    const containers = fileExists("deploy/Dockerfile") or fileExists("Dockerfile");
    const migrations = countSqlMigrations("migrations");
    const dotenv = fileExists(".env");
    if (json) {
        std.debug.print("{{\"akamata\":\"{s}\",\"targets\":{{\"native\":{},\"workers\":{},\"containers\":{}}},\"migrations\":{},\"dotenv\":{}}}\n", .{ VERSION, native, workers, containers, migrations, dotenv });
    } else {
        std.debug.print("Akamata {s}\ntargets: native={s}, workers={s}, containers={s}\nmigrations: {d}\n.env: {s}\n", .{ VERSION, yesNo(native), yesNo(workers), yesNo(containers), migrations, yesNo(dotenv) });
    }
}

fn cmdRoutes(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var json = false;
    var explain_method: ?[]const u8 = null;
    var explain_path: ?[]const u8 = null;
    if (args.len > 0 and std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "explain")) {
        if (args.len != 3) return error.UsageError;
        explain_method = std.mem.sliceTo(args[1], 0);
        explain_path = std.mem.sliceTo(args[2], 0);
    } else for (args) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, arg, "--json")) json = true else return error.UsageError;
    }
    const main_source_owned = readFileAlloc(alloc, "src/main.zig", 2 * 1024 * 1024) catch null;
    defer {
        if (main_source_owned) |source| alloc.free(source);
    }
    const main_source = main_source_owned orelse "";
    if (std.mem.indexOf(u8, main_source, "akamata-openapi") == null) {
        var arena_state: std.heap.ArenaAllocator = .init(alloc);
        defer arena_state.deinit();
        const routes = try client_tui.discoverForTooling(arena_state.allocator());
        if (explain_method) |method| {
            for (routes) |route| if (std.ascii.eqlIgnoreCase(@tagName(route.method), method) and std.mem.eql(u8, route.path, explain_path.?)) {
                std.debug.print("{s} {s}\n  source        {s}\n  streaming     {}\n", .{ method, route.path, route.summary, route.streaming });
                return;
            };
            return error.RouteNotFound;
        }
        if (json) {
            var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());
            try std.json.Stringify.value(routes, .{}, &aw.writer);
            std.debug.print("{s}\n", .{aw.written()});
            return;
        }
        for (routes) |route| std.debug.print("{s: <7} {s} {s}\n", .{ @tagName(route.method), route.path, route.summary });
        std.debug.print("routes: {d} operation(s)\n", .{routes.len});
        return;
    }
    const bytes = try captureCmd(alloc, &.{ "zig", "build", "run", "--", "akamata-openapi" });
    defer alloc.free(bytes);
    if (json) {
        std.debug.print("{s}\n", .{std.mem.trim(u8, bytes, " \t\r\n")});
        return;
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const paths = if (parsed.value == .object) parsed.value.object.get("paths") else null;
    if (paths == null or paths.? != .object) return error.InvalidOpenApi;
    if (explain_method) |wanted_method| {
        const wanted_path = explain_path.?;
        const path = paths.?.object.get(wanted_path) orelse return error.RouteNotFound;
        if (path != .object) return error.InvalidOpenApi;
        var lower_buf: [16]u8 = undefined;
        if (wanted_method.len > lower_buf.len) return error.InvalidMethod;
        for (wanted_method, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        const operation = path.object.get(lower_buf[0..wanted_method.len]) orelse return error.RouteNotFound;
        if (operation != .object) return error.InvalidOpenApi;
        std.debug.print("{s} {s}\n", .{ wanted_method, wanted_path });
        if (operation.object.get("operationId")) |v| if (v == .string) std.debug.print("  operation     {s}\n", .{v.string});
        if (operation.object.get("summary")) |v| if (v == .string) std.debug.print("  summary       {s}\n", .{v.string});
        if (operation.object.get("x-akamata-middleware")) |v| if (v == .array) {
            std.debug.print("  middleware    ", .{});
            for (v.array.items, 0..) |item, i| if (item == .string) std.debug.print("{s}{s}", .{ if (i == 0) "" else " -> ", item.string });
            std.debug.print("\n", .{});
        };
        if (operation.object.get("x-akamata-limits")) |v| if (v == .object) {
            std.debug.print("  budgets       ", .{});
            var limits = v.object.iterator();
            while (limits.next()) |entry| std.debug.print("{s} ", .{entry.key_ptr.*});
            std.debug.print("\n", .{});
        };
        return;
    }
    var count: usize = 0;
    var path_it = paths.?.object.iterator();
    while (path_it.next()) |path| {
        if (path.value_ptr.* != .object) continue;
        var method_it = path.value_ptr.*.object.iterator();
        while (method_it.next()) |method| {
            if (!isHttpMethod(method.key_ptr.*)) continue;
            const summary = if (method.value_ptr.* == .object)
                if (method.value_ptr.*.object.get("summary")) |v| if (v == .string) v.string else "" else ""
            else
                "";
            std.debug.print("{s: <7} {s} {s}\n", .{ method.key_ptr.*, path.key_ptr.*, summary });
            count += 1;
        }
    }
    std.debug.print("routes: {d} operation(s)\n", .{count});
}

fn cmdDoctor(_: std.mem.Allocator, args: []const [:0]const u8) !void {
    var json = false;
    for (args) |raw| {
        if (std.mem.eql(u8, std.mem.sliceTo(raw, 0), "--json")) json = true else return error.UsageError;
    }
    const build = fileExists("build.zig");
    const zon = fileExists("build.zig.zon");
    const source = fileExists("src/main.zig");
    const workspace_build = fileExists("../../build.zig") and fileExists("../../build.zig.zon");
    const workers = fileExists("deploy/wrangler.toml") or fileExists("wrangler.toml");
    const containers = fileExists("deploy/Dockerfile") or fileExists("Dockerfile");
    const healthy = source and ((build and zon) or workspace_build);
    if (json) {
        std.debug.print("{{\"healthy\":{},\"build_zig\":{},\"build_zon\":{},\"workspace_build\":{},\"entrypoint\":{},\"workers\":{},\"containers\":{},\"migrations\":{}}}\n", .{ healthy, build, zon, workspace_build, source, workers, containers, countSqlMigrations("migrations") });
    } else {
        std.debug.print("{s} build.zig\n{s} build.zig.zon\n{s} src/main.zig\n{s} Workers config\n{s} Container config\ninfo migrations: {d}\n", .{ if (build) "ok " else "ERR", if (zon) "ok " else "ERR", if (source) "ok " else "ERR", if (workers) "ok " else "-- ", if (containers) "ok " else "-- ", countSqlMigrations("migrations") });
    }
    if (!healthy) return error.ProjectCheckFailed;
}

fn cmdConfig(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len != 1) return error.UsageError;
    const sub = std.mem.sliceTo(args[0], 0);
    if (!std.mem.eql(u8, sub, "show") and !std.mem.eql(u8, sub, "check")) return error.UsageError;
    const bytes = readFileAlloc(alloc, ".env", 1024 * 1024) catch {
        if (std.mem.eql(u8, sub, "check")) return error.MissingEnvironmentFile;
        std.debug.print("configuration: no .env file\n", .{});
        return;
    };
    defer alloc.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var count: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const present = std.mem.trim(u8, line[eq + 1 ..], " \t").len != 0;
        std.debug.print("{s}: {s}\n", .{ key, if (present) "set" else "missing" });
        if (!present and std.mem.eql(u8, sub, "check")) return error.MissingConfigurationValue;
        count += 1;
    }
    std.debug.print("configuration: {d} key(s), values hidden\n", .{count});
}

fn cmdTest(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) return runChild(alloc, &.{ "zig", "build", "test" }, null);
    if (args.len == 1 and std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "--watch"))
        return runChild(alloc, &.{ "zig", "build", "--watch", "test" }, null);
    return error.UsageError;
}

fn cmdRunner(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) return error.UsageError;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "zig", "build", "run", "--", "akamata-runner" });
    for (args) |arg| try argv.append(alloc, std.mem.sliceTo(arg, 0));
    return runChild(alloc, argv.items, null);
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn cmdGenerate(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 2 or !std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "resource")) return error.UsageError;
    try resourceGenerate(alloc, std.mem.sliceTo(args[1], 0), args[2..]);
}

fn resourceGenerate(alloc: std.mem.Allocator, name: []const u8, args: []const [:0]const u8) !void {
    if (!validIdentifier(name)) return error.InvalidResourceName;
    var pretend = false;
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(alloc);
    for (args) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, arg, "--pretend")) pretend = true else try fields.append(alloc, arg);
    }
    if (fields.items.len == 0) try fields.appendSlice(alloc, &.{ "name:[]const u8", "created_at:?i64" });
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &body);
    defer body = aw.toArrayList();
    try aw.writer.print("const am = @import(\"akamata\");\n\npub const {s} = struct {{\n    id: ?i64 = null,\n", .{name});
    for (fields.items) |field| {
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse return error.InvalidField;
        if (!validIdentifier(field[0..colon]) or colon + 1 == field.len) return error.InvalidField;
        try aw.writer.print("    {s}: {s},\n", .{ field[0..colon], field[colon + 1 ..] });
    }
    try aw.writer.print(
        "\n    pub const __schema = .{{ .table = \"{s}s\", .primary_key = \"id\" }};\n}};\n\npub const Repo = am.model.repo({s});\n\n" ++
            "/// Typed CRUD endpoints. Instantiate with your application State and call register.\n" ++
            "pub fn Routes(comptime State: type) type {{\n" ++
            "    return struct {{\n" ++
            "        const Ctx = am.Context(State);\n" ++
            "        fn list(c: *Ctx) !void {{\n" ++
            "            const rows = try Repo.all(c.db(), c.arena);\n" ++
            "            try c.json(.{{ .items = rows }}, 200);\n" ++
            "        }}\n" ++
            "        fn create(c: *Ctx) !void {{\n" ++
            "            const input = (try c.input({s})) orelse return;\n" ++
            "            try c.json(try Repo.create(c.db(), c.arena, input), 201);\n" ++
            "        }}\n" ++
            "        const List = am.contract.Endpoint(.GET, \"/{s}s\", list, .{{\n" ++
            "            .response = []const {s}, .operation_id = \"list_{s}s\", .tags = &.{{\"{s}s\"}},\n" ++
            "        }});\n" ++
            "        const Create = am.contract.Endpoint(.POST, \"/{s}s\", create, .{{\n" ++
            "            .request = {s}, .response = {s}, .success_status = 201,\n" ++
            "            .operation_id = \"create_{s}\", .tags = &.{{\"{s}s\"}},\n" ++
            "        }});\n" ++
            "        pub fn register(app: *am.App(State)) !void {{ try List.register(app); try Create.register(app); }}\n" ++
            "    }};\n" ++
            "}}\n",
        .{ name, name, name, name, name, name, name, name, name, name, name, name },
    );
    try aw.writer.flush();
    const model_path = try std.fmt.allocPrint(alloc, "src/{s}.zig", .{name});
    defer alloc.free(model_path);
    const test_path = try std.fmt.allocPrint(alloc, "src/{s}_test.zig", .{name});
    defer alloc.free(test_path);
    const test_body = try std.fmt.allocPrint(alloc, "const std = @import(\"std\");\nconst Resource = @import(\"{s}.zig\").{s};\n\ntest \"{s} factory\" {{\n    const value = @import(\"akamata\").testing.factory(Resource, .{{}}).build();\n    try std.testing.expect(value.id == null);\n}}\n", .{ name, name, name });
    defer alloc.free(test_body);
    if (pretend) {
        std.debug.print("create {s}\ncreate {s}\ncreate migrations/<timestamp>_create_{s}s.sql\n", .{ model_path, test_path, name });
        return;
    }
    if (fileExists(model_path) or fileExists(test_path)) return error.ResourceAlreadyExists;
    try writeFileBytes(model_path, aw.writer.buffered());
    try writeFileBytes(test_path, test_body);
    const migration_name = try std.fmt.allocPrint(alloc, "create_{s}s", .{name});
    defer alloc.free(migration_name);
    const generated_args = [_][:0]const u8{try alloc.dupeZ(u8, migration_name)};
    defer alloc.free(generated_args[0]);
    try migrateGenerate(alloc, &generated_args);
    std.debug.print("generated resource `{s}`; import it from your app and register its routes\n", .{name});
}

fn cmdDestroy(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 2 or !std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "resource")) return error.UsageError;
    const name = std.mem.sliceTo(args[1], 0);
    if (!validIdentifier(name)) return error.InvalidResourceName;
    var force = false;
    for (args[2..]) |raw| {
        if (std.mem.eql(u8, std.mem.sliceTo(raw, 0), "--force")) force = true else return error.UsageError;
    }
    if (!force) {
        std.debug.print("destroy is destructive; repeat with --force\n", .{});
        return error.ConfirmationRequired;
    }
    const model_path = try std.fmt.allocPrint(alloc, "src/{s}.zig", .{name});
    defer alloc.free(model_path);
    const test_path = try std.fmt.allocPrint(alloc, "src/{s}_test.zig", .{name});
    defer alloc.free(test_path);
    try removeFileIfExists(alloc, model_path);
    try removeFileIfExists(alloc, test_path);
    std.debug.print("removed generated source files for `{s}`; migrations are retained for data safety\n", .{name});
}

fn cmdApi(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len >= 2 and std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "call")) {
        api_client.runOperation(alloc, std.mem.sliceTo(args[1], 0), args[2..]) catch |err| {
            std.debug.print("akamata api call: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }
    if (args.len != 3 or !std.mem.eql(u8, std.mem.sliceTo(args[0], 0), "diff")) return error.UsageError;
    const before_bytes = try readFileAlloc(alloc, std.mem.sliceTo(args[1], 0), 16 * 1024 * 1024);
    defer alloc.free(before_bytes);
    const after_bytes = try readFileAlloc(alloc, std.mem.sliceTo(args[2], 0), 16 * 1024 * 1024);
    defer alloc.free(after_bytes);
    var before = try std.json.parseFromSlice(std.json.Value, alloc, before_bytes, .{});
    defer before.deinit();
    var after = try std.json.parseFromSlice(std.json.Value, alloc, after_bytes, .{});
    defer after.deinit();
    const bp = if (before.value == .object) before.value.object.get("paths") else null;
    const ap = if (after.value == .object) after.value.object.get("paths") else null;
    if (bp == null or ap == null or bp.? != .object or ap.? != .object) return error.InvalidOpenApi;
    var breaking: usize = 0;
    var paths = bp.?.object.iterator();
    while (paths.next()) |entry| {
        const new_path = ap.?.object.get(entry.key_ptr.*) orelse {
            std.debug.print("BREAKING removed path {s}\n", .{entry.key_ptr.*});
            breaking += 1;
            continue;
        };
        if (entry.value_ptr.* != .object or new_path != .object) continue;
        var methods = entry.value_ptr.*.object.iterator();
        while (methods.next()) |method| {
            if (isHttpMethod(method.key_ptr.*) and new_path.object.get(method.key_ptr.*) == null) {
                std.debug.print("BREAKING removed operation {s} {s}\n", .{ method.key_ptr.*, entry.key_ptr.* });
                breaking += 1;
            }
        }
    }
    breaking += diffComponentSchemas(before.value, after.value);
    if (breaking != 0) return error.BreakingApiChange;
    std.debug.print("api diff: no breaking path, operation, or schema changes\n", .{});
}

fn diffComponentSchemas(before: std.json.Value, after: std.json.Value) usize {
    const old_schemas = nestedObject(before, &.{ "components", "schemas" }) orelse return 0;
    const new_schemas = nestedObject(after, &.{ "components", "schemas" }) orelse return 0;
    var breaking: usize = 0;
    var schemas = old_schemas.iterator();
    while (schemas.next()) |schema| {
        const replacement = new_schemas.get(schema.key_ptr.*) orelse {
            std.debug.print("BREAKING removed schema {s}\n", .{schema.key_ptr.*});
            breaking += 1;
            continue;
        };
        if (schema.value_ptr.* != .object or replacement != .object) continue;
        const old_type = schema.value_ptr.*.object.get("type");
        const new_type = replacement.object.get("type");
        if (!jsonScalarEqual(old_type, new_type)) {
            std.debug.print("BREAKING changed type of schema {s}\n", .{schema.key_ptr.*});
            breaking += 1;
        }
        const old_props = schema.value_ptr.*.object.get("properties");
        const new_props = replacement.object.get("properties");
        if (old_props != null and old_props.? == .object) {
            var props = old_props.?.object.iterator();
            while (props.next()) |prop| {
                const next = if (new_props != null and new_props.? == .object) new_props.?.object.get(prop.key_ptr.*) else null;
                if (next == null) {
                    std.debug.print("BREAKING removed property {s}.{s}\n", .{ schema.key_ptr.*, prop.key_ptr.* });
                    breaking += 1;
                } else if (prop.value_ptr.* == .object and next.? == .object and !jsonScalarEqual(prop.value_ptr.*.object.get("type"), next.?.object.get("type"))) {
                    std.debug.print("BREAKING changed property type {s}.{s}\n", .{ schema.key_ptr.*, prop.key_ptr.* });
                    breaking += 1;
                }
            }
        }
        const old_required = schema.value_ptr.*.object.get("required");
        const new_required = replacement.object.get("required");
        if (new_required != null and new_required.? == .array) for (new_required.?.array.items) |name| {
            if (name == .string and !arrayContainsString(old_required, name.string)) {
                std.debug.print("BREAKING added required property {s}.{s}\n", .{ schema.key_ptr.*, name.string });
                breaking += 1;
            }
        };
    }
    return breaking;
}

fn nestedObject(root: std.json.Value, keys: []const []const u8) ?std.json.ObjectMap {
    var current = root;
    for (keys) |key| {
        if (current != .object) return null;
        current = current.object.get(key) orelse return null;
    }
    return if (current == .object) current.object else null;
}

fn jsonScalarEqual(a: ?std.json.Value, b: ?std.json.Value) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    if (a.? == .string and b.? == .string) return std.mem.eql(u8, a.?.string, b.?.string);
    if (a.? == .null and b.? == .null) return true;
    if (a.? == .bool and b.? == .bool) return a.?.bool == b.?.bool;
    if (a.? == .integer and b.? == .integer) return a.?.integer == b.?.integer;
    if (a.? == .float and b.? == .float) return a.?.float == b.?.float;
    return false;
}

fn arrayContainsString(value: ?std.json.Value, needle: []const u8) bool {
    if (value == null or value.? != .array) return false;
    for (value.?.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    return false;
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}
fn isHttpMethod(value: []const u8) bool {
    return std.mem.eql(u8, value, "get") or std.mem.eql(u8, value, "post") or std.mem.eql(u8, value, "put") or std.mem.eql(u8, value, "patch") or std.mem.eql(u8, value, "delete") or std.mem.eql(u8, value, "head") or std.mem.eql(u8, value, "options");
}
fn countSqlMigrations(path: []const u8) usize {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return 0;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const dir = opendir(@ptrCast(&path_buf)) orelse return 0;
    defer _ = closedir(dir);
    var count: usize = 0;
    while (readdir(dir)) |entry| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        if (std.mem.endsWith(u8, name, ".sql")) count += 1;
    }
    return count;
}
fn removeFileIfExists(alloc: std.mem.Allocator, path: []const u8) !void {
    if (!fileExists(path)) return;
    const z = try alloc.dupeZ(u8, path);
    defer alloc.free(z);
    if (unlink(z.ptr) != 0) return error.RemoveFailed;
}
extern "c" fn unlink(path: [*:0]const u8) c_int;

// ---- migrate ----

fn cmdMigrate(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) {
        std.debug.print("usage: akamata migrate <generate|up> ...\n", .{});
        return error.UsageError;
    }
    const sub = std.mem.sliceTo(args[0], 0);
    if (isHelpArg(sub)) return commandUsage("migrate");
    if (args.len >= 2 and isHelpArg(std.mem.sliceTo(args[1], 0))) return commandUsage("migrate");
    if (std.mem.eql(u8, sub, "generate")) return migrateGenerate(alloc, args[1..]);
    if (std.mem.eql(u8, sub, "up")) return migrateRun(alloc, "migrate-up", args[1..]);
    if (std.mem.eql(u8, sub, "status")) return migrateRun(alloc, "migrate-status", args[1..]);
    if (std.mem.eql(u8, sub, "plan")) return migrateRun(alloc, "migrate-plan", args[1..]);
    if (std.mem.eql(u8, sub, "rollback")) return migrateRun(alloc, "migrate-rollback", args[1..]);
    if (std.mem.eql(u8, sub, "redo")) return migrateRun(alloc, "migrate-redo", args[1..]);
    std.debug.print("unknown migrate subcommand: {s}\n", .{sub});
    return error.UsageError;
}

const migration_file_template =
    \\-- akamata migration
    \\-- Generated: {s}
    \\-- Name: {s}
    \\
    \\-- migrate:up
    \\-- Write forward SQL here. Statements run in the order they appear.
    \\
    \\-- migrate:down
    \\-- Write rollback SQL here. Leave empty only for an intentionally irreversible migration.
    \\
;

fn migrateGenerate(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) {
        std.debug.print("usage: akamata migrate generate <name> [--dir=migrations]\n", .{});
        return error.UsageError;
    }
    const name = std.mem.sliceTo(args[0], 0);
    var dir: []const u8 = "migrations";
    for (args[1..]) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, a, "--dir=")) dir = a[6..];
    }
    try makeDirRecursive(dir);

    // Timestamp version: YYYYMMDDHHMMSS in UTC.
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ts = nowVersion(arena);
    const fname = try std.fmt.allocPrint(arena, "{s}/{s}_{s}.sql", .{ dir, ts, name });
    const body = try std.fmt.allocPrint(arena, migration_file_template, .{ ts, name });
    try writeFileBytes(fname, body);
    std.debug.print("created {s}\n", .{fname});
}

extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn gmtime(timer: *const c_long) ?*Tm;
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

fn nowVersion(arena: std.mem.Allocator) []const u8 {
    const t = time(null);
    const tm = gmtime(&t) orelse return "00000000000000";
    return std.fmt.allocPrint(arena, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
        @as(u32, @intCast(tm.tm_year + 1900)),
        @as(u32, @intCast(tm.tm_mon + 1)),
        @as(u32, @intCast(tm.tm_mday)),
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
    }) catch "00000000000000";
}

/// `akamata migrate up` is a thin wrapper that delegates to the app binary's
/// `migrate-up` subcommand (cargo-style). The app sets up its DB url, loads
/// the migration directory, and runs `am.model.migrate.Migrator.applyAll`.
fn migrateRun(alloc: std.mem.Allocator, mode: []const u8, args: []const [:0]const u8) !void {
    var dir: []const u8 = "migrations";
    for (args) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, arg, "--dir=")) dir = arg[6..];
    }
    if (!directoryExists(dir)) {
        std.debug.print("migrate: {s}/ does not exist; nothing to apply. Create one with `akamata migrate generate <name>`.\n", .{dir});
        return;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "zig", "build", "run", "--", mode });
    for (args) |raw| try argv.append(alloc, std.mem.sliceTo(raw, 0));
    runChild(alloc, argv.items, null) catch |err| {
        std.debug.print("migrate: application runner failed. Ensure `zig build run -- migrate-up` works in this project and DATABASE_URL is valid.\n", .{});
        return err;
    };
}

fn directoryExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const dir = opendir(@ptrCast(&buf)) orelse return false;
    _ = closedir(dir);
    return true;
}

// ---- db ----

fn cmdDb(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) {
        std.debug.print("db: missing SQL file path\n", .{});
        return error.UsageError;
    }
    const sql_file: []const u8 = std.mem.sliceTo(args[0], 0);
    var mode: []const u8 = "--local";
    var config_path: ?[]const u8 = null;
    for (args[1..]) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, a, "--remote")) mode = "--remote" else if (std.mem.eql(u8, a, "--local")) mode = "--local" else if (std.mem.startsWith(u8, a, "--config=")) config_path = a[9..];
    }

    // Pick the D1 name from the wrangler.toml (so we don't hard-code "DB").
    const cfg = config_path orelse defaultConfigPath();
    var db_name: []const u8 = "DB";
    var owned: ?D1Info = null;
    defer if (owned) |i| {
        alloc.free(i.binding);
        alloc.free(i.name);
        alloc.free(i.id);
    };
    if (cfg) |c| {
        if (try readD1FromConfig(alloc, c)) |info| {
            owned = info;
            db_name = info.name;
            const argv = if (config_path != null)
                &[_][]const u8{ "npx", "wrangler", "d1", "execute", db_name, mode, "--config", c, "--file", sql_file, "--yes" }
            else
                &[_][]const u8{ "npx", "wrangler", "d1", "execute", db_name, mode, "--file", sql_file, "--yes" };
            return runChild(alloc, argv, null);
        }
    }
    try runChild(alloc, &.{ "npx", "wrangler", "d1", "execute", db_name, mode, "--file", sql_file, "--yes" }, null);
}

extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn chdir(p: [*:0]const u8) c_int;

// === dev hot-reload primitives (POSIX libc) ===

extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn killpg(pgrp: c_int, sig: c_int) c_int;
extern "c" fn setpgid(pid: c_int, pgid: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn sigaction(sig: c_int, act: *const Sigaction, oact: ?*Sigaction) c_int;

const SIGINT = 2;
const SIGKILL = 9;
const SIGTERM = 15;
const WNOHANG = 1;
const DT_DIR = 4;
const DT_REG = 8;

const Timespec = extern struct { sec: c_long, nsec: c_long };

// `struct stat` is OS-specific; we only read st_mtim(espec). These layouts
// match darwin (_DARWIN_FEATURE_64_BIT_INODE, the default) and linux x86_64.
const stat_t = switch (builtin.os.tag) {
    .macos => extern struct {
        dev: i32,
        mode: u16,
        nlink: u16,
        ino: u64,
        uid: u32,
        gid: u32,
        rdev: i32,
        atim: Timespec,
        mtim: Timespec,
        ctim: Timespec,
        birthtim: Timespec,
        size: i64,
        blocks: i64,
        blksize: i32,
        flags: u32,
        gen: u32,
        lspare: i32,
        qspare: [2]i64,
    },
    else => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        _pad0: u32,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atim: Timespec,
        mtim: Timespec,
        ctim: Timespec,
        _unused: [3]i64,
    },
};
extern "c" fn stat(path: [*:0]const u8, buf: *stat_t) c_int;

const DIR = opaque {};
const dirent = switch (builtin.os.tag) {
    .macos => extern struct {
        ino: u64,
        seekoff: u64,
        reclen: u16,
        namlen: u16,
        type: u8,
        name: [1024]u8,
    },
    else => extern struct {
        ino: u64,
        off: i64,
        reclen: u16,
        type: u8,
        name: [256]u8,
    },
};
extern "c" fn opendir(path: [*:0]const u8) ?*DIR;
extern "c" fn readdir(d: *DIR) ?*dirent;
extern "c" fn closedir(d: *DIR) c_int;

fn sleepMs(ms: u64) void {
    const ts = Timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = nanosleep(&ts, null);
}

// `struct sigaction`. We only set sa_handler + sa_flags (no SA_RESTART, so a
// signal interrupts nanosleep and the loop checks the flag promptly). Layouts
// differ per-OS; sa_handler is the first field on both darwin and linux.
const Sigaction = switch (builtin.os.tag) {
    .macos => extern struct {
        handler: *const fn (c_int) callconv(.c) void,
        mask: u32 = 0,
        flags: c_int = 0,
    },
    else => extern struct {
        handler: *const fn (c_int) callconv(.c) void,
        mask: [16]c_ulong = [_]c_ulong{0} ** 16, // sigset_t (over-sized; zeroed)
        flags: c_int = 0,
        restorer: ?*const fn () callconv(.c) void = null,
    },
};

// Ctrl-C handling for the dev loop. The handler runs in async-signal context,
// so it does ONLY signal-safe work: flip an atomic flag. The main loop (and its
// `defer`) owns process teardown via stopChild — we do not kill from the
// handler, which keeps the spawn/record sequence race-free (the child is in its
// own process group, isolated from the terminal's Ctrl-C; dev is its sole
// killer). `dev_running` is atomic so the loop re-reads it after the handler
// fires (a plain `var` could be cached in a register under optimization).
var dev_running: std.atomic.Value(bool) = .init(true);

fn devSigintHandler(_: c_int) callconv(.c) void {
    dev_running.store(false, .seq_cst);
}

fn dev_install_sigint() void {
    // flags defaults to 0 — deliberately NO SA_RESTART, so nanosleep returns
    // EINTR on signal and the loop checks dev_running promptly.
    const act = Sigaction{ .handler = devSigintHandler };
    _ = sigaction(SIGINT, &act, null);
    _ = sigaction(SIGTERM, &act, null); // also stop cleanly on `kill`
}

fn runChild(alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !void {
    // Build a shell command line. Each argv element is single-quoted with any
    // embedded single quote escaped as `'\''`. Sufficient for the trusted
    // commands we issue (zig, wrangler, docker).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (argv, 0..) |a, i| {
        if (i > 0) try buf.append(alloc, ' ');
        try buf.append(alloc, '\'');
        for (a) |ch| {
            if (ch == '\'') {
                try buf.appendSlice(alloc, "'\\''");
            } else {
                try buf.append(alloc, ch);
            }
        }
        try buf.append(alloc, '\'');
    }

    if (cwd) |c| {
        const cwd_z = try alloc.dupeZ(u8, c);
        defer alloc.free(cwd_z);
        if (chdir(cwd_z.ptr) != 0) return error.ChildFailed;
    }

    try buf.append(alloc, 0);
    const cmd: [*:0]const u8 = @ptrCast(buf.items.ptr);
    const rc = system(cmd);
    if (rc != 0) {
        std.debug.print("child exited with status {d}\n", .{rc});
        return error.ChildFailed;
    }
}
