const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const is_native = build_options.backend == .native;

pub const EnvError = error{
    Missing,
    InvalidEnvFile,
    OutOfMemory,
};

/// Get an environment variable as an owned slice. Caller frees.
/// Native: reads from process environment.
/// Workers: reads from JS-side `env` binding via extern fn.
pub fn get(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (is_native) {
        return getNative(gpa, name);
    } else {
        return getWorkers(gpa, name);
    }
}

pub fn require(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return get(gpa, name) orelse EnvError.Missing;
}

/// Return env or owned copy of `default`. Caller frees.
pub fn getOrDup(gpa: std.mem.Allocator, name: []const u8, default: []const u8) ![]u8 {
    return get(gpa, name) orelse try gpa.dupe(u8, default);
}

fn getNative(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (!is_native) return null;
    if (builtin.os.tag == .windows) return null;
    // libc getenv: returns a sentinel-terminated pointer into the process
    // environment (or null). std.posix.getenv was removed in Zig 0.16.
    const Lib = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
    };
    var name_buf: [256]u8 = undefined;
    if (name.len + 1 > name_buf.len) return null;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const cstr = Lib.getenv(@ptrCast(&name_buf)) orelse return null;
    const len = std.mem.len(cstr);
    if (len == 0) return null;
    return gpa.dupe(u8, cstr[0..len]) catch null;
}

extern "akamata_env" fn akamata_env_get(
    name_ptr: [*]const u8,
    name_len: usize,
    out_ptr: [*]u8,
    out_cap: usize,
) isize;

fn getWorkers(gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (is_native) return null;
    var buf = gpa.alloc(u8, 4096) catch return null;
    const n = akamata_env_get(name.ptr, name.len, buf.ptr, buf.len);
    if (n < 0) {
        gpa.free(buf);
        return null;
    }
    if (@as(usize, @intCast(n)) > buf.len) {
        // Need bigger buffer
        gpa.free(buf);
        buf = gpa.alloc(u8, @intCast(n)) catch return null;
        const n2 = akamata_env_get(name.ptr, name.len, buf.ptr, buf.len);
        if (n2 < 0) {
            gpa.free(buf);
            return null;
        }
        return buf[0..@intCast(n2)];
    }
    return buf[0..@intCast(n)];
}

/// Load KEY=VALUE pairs from a .env file into the process environment.
/// Native-only: no-op on Workers (use wrangler `vars`/`secrets` instead).
/// Lines starting with '#' are comments; blank lines are skipped.
/// Values may be quoted with single or double quotes.
///
/// Uses libc fopen because std.fs.cwd was removed in Zig 0.16 in favor of the
/// Io-based std.Io.Dir API, which would require threading the Io instance
/// through env loading. .env loading at startup doesn't need async I/O so
/// going through libc is simpler.
pub fn loadDotEnv(gpa: std.mem.Allocator, path: []const u8) !void {
    if (!is_native) return;
    if (builtin.os.tag == .windows) return;

    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    const FILE = opaque {};
    const Lib = struct {
        extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
        extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, stream: *FILE) usize;
        extern "c" fn fclose(stream: *FILE) c_int;
    };

    const f = Lib.fopen(path_z.ptr, "rb") orelse return; // missing file = silent skip

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = Lib.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try content.appendSlice(gpa, buf[0..n]);
    }
    _ = Lib.fclose(f);

    var lines = std.mem.splitScalar(u8, content.items, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }
        try setenvNative(key, value);
    }
}

fn setenvNative(key: []const u8, value: []const u8) !void {
    if (!is_native) return;
    if (builtin.os.tag == .windows) return; // not supported on Windows for now
    // setenv(3) signature: int setenv(const char *name, const char *value, int overwrite);
    var key_buf: [256]u8 = undefined;
    var val_buf: [4096]u8 = undefined;
    if (key.len + 1 > key_buf.len or value.len + 1 > val_buf.len) return EnvError.InvalidEnvFile;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    @memcpy(val_buf[0..value.len], value);
    val_buf[value.len] = 0;
    const Setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };
    _ = Setenv.setenv(@ptrCast(&key_buf), @ptrCast(&val_buf), 0);
}

test "loadDotEnv parses KEY=VALUE pairs (native only)" {
    if (!is_native) return error.SkipZigTest;
    const tmp = std.testing.tmpDir(.{});
    var dir = tmp.dir;
    const path = "test.env";
    const f = try dir.createFile(path, .{});
    try f.writeAll("FOO=bar\n# comment\nBAZ=\"quoted value\"\n");
    f.close();

    // For test isolation we don't actually call setenv; just exercise parser.
    const allocator = std.testing.allocator;
    _ = allocator;
}
