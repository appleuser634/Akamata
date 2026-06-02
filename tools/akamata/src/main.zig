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
    if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "build")) {
        try cmdBuild(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "dev")) {
        try cmdDev(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "deploy")) {
        try cmdDeploy(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "db")) {
        try cmdDb(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "migrate")) {
        try cmdMigrate(alloc, args[2..]);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
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

const VERSION = "0.3.0";

const known_commands = [_][]const u8{
    "init", "build", "dev", "deploy", "db", "migrate", "help", "version",
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
        \\
        \\Commands:
        \\  init <name> [--target=native|workers|containers|both]
        \\      Scaffold a new Akamata app.
        \\  build [--workers|--containers]
        \\      Build the current app (native by default).
        \\  dev
        \\      Run the current app natively (alias for `zig build run`).
        \\  deploy [--workers|--containers] [--config=PATH] [--migrate=SQL]
        \\      Build and deploy. For --workers:
        \\        * --config=PATH      wrangler.toml location
        \\                             (default: deploy/wrangler.toml, then wrangler.toml)
        \\        * --migrate=SQL      apply the SQL file to the remote D1 before deploy.
        \\                             If the D1 in wrangler.toml has the placeholder
        \\                             database_id, it is auto-created and the ID is
        \\                             written back into the config.
        \\  db <sql-file> [--local|--remote] [--config=PATH]
        \\      Run a SQL migration against the D1 binding `DB`.
        \\  migrate generate <name> [--dir=migrations]
        \\      Create a new migration file `<timestamp>_<name>.sql` in
        \\      <dir> (default: ./migrations).
        \\  migrate up [--dir=migrations] [--target=VERSION]
        \\      Apply all pending migrations against the active database.
        \\      Reads DATABASE_URL from env/.env (same as your app). Records
        \\      each applied version in the `schema_migrations` table.
        \\
    ;
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
    for (args[1..]) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, a, "--target=")) {
            const v = a[9..];
            if (std.mem.eql(u8, v, "native")) opts.target = .native
            else if (std.mem.eql(u8, v, "workers")) opts.target = .workers
            else if (std.mem.eql(u8, v, "containers")) opts.target = .containers
            else if (std.mem.eql(u8, v, "both")) opts.target = .both
            else {
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
    const fingerprint_str = try std.fmt.allocPrint(alloc, "0x{x:0>16}", .{computeFingerprint(opts.name)});
    defer alloc.free(fingerprint_str);
    try renderFile(alloc, opts.name, "build.zig.zon", tmpl_build_zon, &.{
        .{ .key = "{{NAME}}", .val = opts.name },
        .{ .key = "{{NAME_ENUM}}", .val = opts.name },
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

fn cmdBuild(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "zig");
    try argv.append(alloc, "build");
    for (args) |raw| {
        const a = std.mem.sliceTo(raw, 0);
        if (std.mem.eql(u8, a, "--workers")) {
            try argv.append(alloc, "-Dbackend=workers");
            try argv.append(alloc, "-Doptimize=ReleaseSmall");
        } else if (std.mem.eql(u8, a, "--containers")) {
            try argv.append(alloc, "-Dtarget=x86_64-linux-musl");
            try argv.append(alloc, "-Doptimize=ReleaseFast");
        }
    }
    try runChild(alloc, argv.items, null);
}

fn cmdDev(alloc: std.mem.Allocator, _: []const [:0]const u8) !void {
    try runChild(alloc, &.{ "zig", "build", "run" }, null);
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
        if (std.mem.eql(u8, a, "--workers")) target_workers = true
        else if (std.mem.eql(u8, a, "--containers")) target_containers = true
        else if (std.mem.startsWith(u8, a, "--config=")) config_path = a[9..]
        else if (std.mem.startsWith(u8, a, "--migrate=")) migrate_path = a[10..];
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
        std.debug.print("==> akamata: building wasm (ReleaseSmall)\n", .{});
        try runChild(alloc, &.{ "zig", "build", "-Dbackend=workers", "-Doptimize=ReleaseSmall" }, null);
        std.debug.print("==> akamata: wrangler deploy\n", .{});
        try runChild(alloc, &.{ "npx", "wrangler", "deploy", "--config", cfg }, null);
    }
    if (target_containers) {
        try runChild(alloc, &.{ "zig", "build", "-Dtarget=x86_64-linux-musl", "-Doptimize=ReleaseFast" }, null);
        try runChild(alloc, &.{ "docker", "build", "-f", "deploy/Dockerfile", "-t", "akamata-app", "." }, null);
    }
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
        if (std.mem.eql(u8, k, "binding")) binding = v
        else if (std.mem.eql(u8, k, "database_name")) name = v
        else if (std.mem.eql(u8, k, "database_id")) id = v;
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

// ---- migrate ----

fn cmdMigrate(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) {
        std.debug.print("usage: akamata migrate <generate|up> ...\n", .{});
        return error.UsageError;
    }
    const sub = std.mem.sliceTo(args[0], 0);
    if (std.mem.eql(u8, sub, "generate")) return migrateGenerate(alloc, args[1..]);
    if (std.mem.eql(u8, sub, "up")) return migrateUp(alloc, args[1..]);
    std.debug.print("unknown migrate subcommand: {s}\n", .{sub});
    return error.UsageError;
}

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
    const template =
        \\-- akamata migration
        \\-- Generated: {s}
        \\-- Name: {s}
        \\
        \\-- Write SQL statements here, ; to separate. Statements run in the
        \\-- order they appear. Recommend each is idempotent (IF NOT EXISTS).
        \\
    ;
    const body = try std.fmt.allocPrint(arena, template, .{ ts, name });
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
fn migrateUp(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "zig", "build", "run", "--", "migrate-up" });
    for (args) |raw| try argv.append(alloc, std.mem.sliceTo(raw, 0));
    try runChild(alloc, argv.items, null);
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
        if (std.mem.eql(u8, a, "--remote")) mode = "--remote"
        else if (std.mem.eql(u8, a, "--local")) mode = "--local"
        else if (std.mem.startsWith(u8, a, "--config=")) config_path = a[9..];
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
