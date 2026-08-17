//! Interactive HTTP client for Akamata applications.
const std = @import("std");
const am = @import("akamata");

const Header = am.http_client.Header;

const Options = struct {
    base_url: []const u8 = "http://127.0.0.1:8080",
    headers: std.ArrayList(Header) = .empty,
    queries: std.ArrayList([]const u8) = .empty,
    params: std.ArrayList([]const u8) = .empty,
    body: []const u8 = "",
    include: bool = false,
    raw: bool = false,
    fail_status: bool = false,
    max_bytes: usize = 4 * 1024 * 1024,

    fn deinit(self: *Options, alloc: std.mem.Allocator) void {
        self.headers.deinit(alloc);
        self.queries.deinit(alloc);
        self.params.deinit(alloc);
    }
};

pub fn run(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    return runWithAllocator(arena_state.allocator(), args);
}

fn runWithAllocator(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len == 0) return error.UsageError;
    var method: am.http_client.Method = .GET;
    var path_index: usize = 0;
    if (parseMethod(std.mem.sliceTo(args[0], 0))) |parsed| {
        method = parsed;
        path_index = 1;
    }
    if (path_index >= args.len) return error.UsageError;
    const path = std.mem.sliceTo(args[path_index], 0);
    var opts: Options = .{};
    defer opts.deinit(alloc);
    try parseOptions(alloc, &opts, args[path_index + 1 ..]);
    try sendAndPrint(alloc, method, path, &opts);
}

pub fn runOperation(alloc: std.mem.Allocator, operation_id: []const u8, args: []const [:0]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    return runOperationWithAllocator(arena_state.allocator(), operation_id, args);
}

fn runOperationWithAllocator(alloc: std.mem.Allocator, operation_id: []const u8, args: []const [:0]const u8) !void {
    var opts: Options = .{};
    defer opts.deinit(alloc);
    var spec_path: []const u8 = "/openapi.json";
    var filtered: std.ArrayList([:0]const u8) = .empty;
    defer filtered.deinit(alloc);
    for (args) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, arg, "--spec=")) spec_path = arg[7..] else try filtered.append(alloc, raw);
    }
    try parseOptions(alloc, &opts, filtered.items);
    const spec_url = try buildUrl(alloc, opts.base_url, spec_path, &.{});
    defer alloc.free(spec_url);
    const spec_response = try am.http_client.send(alloc, .{ .method = .GET, .url = spec_url, .max_response_bytes = opts.max_bytes });
    if (spec_response.status < 200 or spec_response.status >= 300) return error.OpenApiUnavailable;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, spec_response.body, .{}) catch return error.InvalidOpenApi;
    defer parsed.deinit();
    const operation = findOperation(parsed.value, operation_id) orelse return error.OperationNotFound;
    const expanded = try expandPath(alloc, operation.path, opts.params.items);
    defer alloc.free(expanded);
    try sendAndPrint(alloc, operation.method, expanded, &opts);
}

fn parseOptions(alloc: std.mem.Allocator, opts: *Options, args: []const [:0]const u8) !void {
    var wants_json = false;
    for (args) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, arg, "--base-url=")) {
            opts.base_url = std.mem.trimEnd(u8, arg[11..], "/");
        } else if (std.mem.startsWith(u8, arg, "--header=")) {
            const header = try parseHeader(arg[9..]);
            try opts.headers.append(alloc, header);
        } else if (std.mem.startsWith(u8, arg, "-H=")) {
            const header = try parseHeader(arg[3..]);
            try opts.headers.append(alloc, header);
        } else if (std.mem.startsWith(u8, arg, "--bearer=")) {
            if (std.mem.indexOfAny(u8, arg[9..], "\r\n") != null) return error.InvalidHeader;
            const value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{arg[9..]});
            try opts.headers.append(alloc, .{ .name = "authorization", .value = value });
        } else if (std.mem.startsWith(u8, arg, "--query=")) {
            try validatePair(arg[8..]);
            try opts.queries.append(alloc, arg[8..]);
        } else if (std.mem.startsWith(u8, arg, "--param=")) {
            try validatePair(arg[8..]);
            try opts.params.append(alloc, arg[8..]);
        } else if (std.mem.startsWith(u8, arg, "--json=")) {
            opts.body = try bodyValue(alloc, arg[7..]);
            var validation = std.json.parseFromSlice(std.json.Value, alloc, opts.body, .{}) catch return error.InvalidJsonBody;
            validation.deinit();
            wants_json = true;
        } else if (std.mem.startsWith(u8, arg, "--data=")) {
            opts.body = try bodyValue(alloc, arg[7..]);
        } else if (std.mem.eql(u8, arg, "--include")) {
            opts.include = true;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            opts.raw = true;
        } else if (std.mem.eql(u8, arg, "--fail")) {
            opts.fail_status = true;
        } else if (std.mem.startsWith(u8, arg, "--max-bytes=")) {
            opts.max_bytes = std.fmt.parseInt(usize, arg[12..], 10) catch return error.InvalidMaxBytes;
            if (opts.max_bytes == 0 or opts.max_bytes > 64 * 1024 * 1024) return error.InvalidMaxBytes;
        } else return error.UnknownClientOption;
    }
    if (wants_json) {
        var has_content_type = false;
        for (opts.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) has_content_type = true;
        }
        if (!has_content_type) try opts.headers.append(alloc, .{ .name = "content-type", .value = "application/json" });
    }
}

fn bodyValue(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0 or raw[0] != '@') return raw;
    if (raw.len == 1) return error.MissingBodyFile;
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, raw[1..], alloc, .limited(16 * 1024 * 1024)) catch
        return error.BodyFileUnreadable;
}

fn sendAndPrint(alloc: std.mem.Allocator, method: am.http_client.Method, path: []const u8, opts: *const Options) !void {
    const url = try buildUrl(alloc, opts.base_url, path, opts.queries.items);
    defer alloc.free(url);
    const response = try am.http_client.send(alloc, .{
        .method = method,
        .url = url,
        .headers = opts.headers.items,
        .body = opts.body,
        .max_response_bytes = opts.max_bytes,
    });
    var stdout_buf: [4096]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout.interface;
    if (opts.include) {
        try w.writeAll(response.headers_raw);
        if (!std.mem.endsWith(u8, response.headers_raw, "\n")) try w.writeByte('\n');
        try w.writeByte('\n');
    }
    if (!opts.raw and response.body.len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, response.body, .{}) catch null;
        if (parsed) |*json| {
            defer json.deinit();
            try std.json.Stringify.value(json.value, .{ .whitespace = .indent_2 }, w);
            try w.writeByte('\n');
        } else {
            try w.writeAll(response.body);
            if (!std.mem.endsWith(u8, response.body, "\n")) try w.writeByte('\n');
        }
    } else {
        try w.writeAll(response.body);
    }
    try w.flush();
    if (opts.fail_status and response.status >= 400) return error.HttpStatusFailure;
}

const Operation = struct { method: am.http_client.Method, path: []const u8 };

fn findOperation(root: std.json.Value, operation_id: []const u8) ?Operation {
    if (root != .object) return null;
    const paths = root.object.get("paths") orelse return null;
    if (paths != .object) return null;
    var path_it = paths.object.iterator();
    while (path_it.next()) |path_entry| {
        if (path_entry.value_ptr.* != .object) continue;
        var method_it = path_entry.value_ptr.*.object.iterator();
        while (method_it.next()) |method_entry| {
            const method = parseMethod(method_entry.key_ptr.*) orelse continue;
            if (method_entry.value_ptr.* != .object) continue;
            const id = method_entry.value_ptr.*.object.get("operationId") orelse continue;
            if (id == .string and std.mem.eql(u8, id.string, operation_id))
                return .{ .method = method, .path = path_entry.key_ptr.* };
        }
    }
    return null;
}

fn expandPath(alloc: std.mem.Allocator, path: []const u8, params: []const []const u8) ![]u8 {
    var out = try alloc.dupe(u8, path);
    for (params) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse unreachable;
        const marker = try std.fmt.allocPrint(alloc, "{{{s}}}", .{pair[0..eq]});
        defer alloc.free(marker);
        const encoded = try percentEncode(alloc, pair[eq + 1 ..]);
        defer alloc.free(encoded);
        const replaced = try std.mem.replaceOwned(u8, alloc, out, marker, encoded);
        alloc.free(out);
        out = replaced;
    }
    if (std.mem.indexOfScalar(u8, out, '{') != null or std.mem.indexOfScalar(u8, out, '}') != null) {
        alloc.free(out);
        return error.MissingPathParameter;
    }
    return out;
}

fn buildUrl(alloc: std.mem.Allocator, base: []const u8, path: []const u8, queries: []const []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, path, "\r\n") != null) return error.InvalidUrl;
    var out: std.ArrayList(u8) = .empty;
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        try out.appendSlice(alloc, path);
    } else {
        if (!std.mem.startsWith(u8, base, "http://") and !std.mem.startsWith(u8, base, "https://")) return error.InvalidBaseUrl;
        try out.appendSlice(alloc, base);
        if (!std.mem.startsWith(u8, path, "/")) try out.append(alloc, '/');
        try out.appendSlice(alloc, path);
    }
    for (queries, 0..) |pair, i| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse unreachable;
        try out.append(alloc, if (std.mem.indexOfScalar(u8, out.items, '?') == null and i == 0) '?' else '&');
        const key = try percentEncode(alloc, pair[0..eq]);
        defer alloc.free(key);
        const value = try percentEncode(alloc, pair[eq + 1 ..]);
        defer alloc.free(value);
        try out.appendSlice(alloc, key);
        try out.append(alloc, '=');
        try out.appendSlice(alloc, value);
    }
    return out.toOwnedSlice(alloc);
}

fn percentEncode(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(alloc, c);
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseHeader(raw: []const u8) !Header {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return error.InvalidHeader;
    const name = std.mem.trim(u8, raw[0..colon], " \t");
    const value = std.mem.trim(u8, raw[colon + 1 ..], " \t");
    if (name.len == 0 or std.mem.indexOfAny(u8, raw, "\r\n") != null) return error.InvalidHeader;
    return .{ .name = name, .value = value };
}
fn validatePair(raw: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidKeyValue;
    if (eq == 0 or std.mem.indexOfAny(u8, raw, "\r\n") != null) return error.InvalidKeyValue;
}
fn parseMethod(raw: []const u8) ?am.http_client.Method {
    inline for (std.meta.tags(am.http_client.Method)) |method| {
        if (std.ascii.eqlIgnoreCase(raw, @tagName(method))) return method;
    }
    return null;
}

test "URL builder encodes query values" {
    const url = try buildUrl(std.testing.allocator, "http://localhost:8080", "/notes", &.{"q=hello world"});
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:8080/notes?q=hello%20world", url);
}

test "OpenAPI operation lookup and path expansion" {
    const source = "{\"paths\":{\"/notes/{id}\":{\"get\":{\"operationId\":\"getNote\"}}}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const operation = findOperation(parsed.value, "getNote").?;
    try std.testing.expectEqual(am.http_client.Method.GET, operation.method);
    const path = try expandPath(std.testing.allocator, operation.path, &.{"id=a/b"});
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/notes/a%2Fb", path);
}
