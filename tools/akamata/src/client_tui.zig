//! Full-screen terminal client for exploring and calling Akamata APIs.
const std = @import("std");
const am = @import("akamata");

const Endpoint = struct {
    method: am.http_client.Method,
    path: []const u8,
    summary: []const u8,
    operation_id: []const u8,
};

const State = struct {
    endpoints: []const Endpoint,
    selected: usize = 0,
    base_url: []const u8,
    request_method: am.http_client.Method,
    request_path: []const u8 = "",
    body: []const u8 = "",
    header: []const u8 = "",
    response_body: []const u8 = "Press Enter to send the selected request.",
    response_status: ?u16 = null,
    message: []const u8 = "j/k select · Enter send · m method · e path · h header · b body · u URL · r reload · q quit",
};

pub fn run(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    var base_url: []const u8 = "http://127.0.0.1:8080";
    for (args) |raw| {
        const arg = std.mem.sliceTo(raw, 0);
        if (std.mem.startsWith(u8, arg, "--base-url=")) base_url = std.mem.trimEnd(u8, arg[11..], "/") else if (!std.mem.eql(u8, arg, "--tui")) return error.UnknownTuiOption;
    }

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var endpoints = discover(arena, base_url) catch &.{};
    if (endpoints.len == 0) endpoints = try arena.dupe(Endpoint, &.{.{ .method = .GET, .path = "/", .summary = "Manual request", .operation_id = "" }});

    var state: State = .{ .endpoints = endpoints, .base_url = base_url, .request_method = endpoints[0].method, .request_path = endpoints[0].path };
    enterScreen();
    defer leaveScreen();
    while (true) {
        draw(&state);
        const key = readKey() catch return error.TerminalReadFailed;
        switch (key) {
            'q', 3 => return,
            'j' => if (state.selected + 1 < state.endpoints.len) {
                state.selected += 1;
                state.request_method = state.endpoints[state.selected].method;
                state.request_path = state.endpoints[state.selected].path;
            },
            'k' => if (state.selected > 0) {
                state.selected -= 1;
                state.request_method = state.endpoints[state.selected].method;
                state.request_path = state.endpoints[state.selected].path;
            },
            'm' => state.request_method = nextMethod(state.request_method),
            'e' => state.request_path = try prompt(arena, "Request path or absolute URL", state.request_path),
            'b' => state.body = try prompt(arena, "JSON/raw body (empty clears)", state.body),
            'h' => state.header = try prompt(arena, "Header as Name: Value (empty clears)", state.header),
            'u' => state.base_url = std.mem.trimEnd(u8, try prompt(arena, "Base URL", state.base_url), "/"),
            'r' => {
                const refreshed = discover(arena, state.base_url) catch &.{};
                if (refreshed.len > 0) {
                    state.endpoints = refreshed;
                    state.selected = 0;
                    state.request_method = refreshed[0].method;
                    state.request_path = refreshed[0].path;
                    state.message = "Routes refreshed from application metadata.";
                } else state.message = "Discovery failed; keeping the current route list.";
            },
            '\r', '\n' => {
                if (try fillPathParams(arena, &state)) try execute(alloc, &state);
            },
            '?' => state.message = "j/k select · Enter send · m method · e path · h header · b body · u URL · r reload · q quit",
            else => {},
        }
    }
}

fn discover(alloc: std.mem.Allocator, base_url: []const u8) ![]const Endpoint {
    // Preferred path: application runner inspection. No HTTP route is exposed.
    const local = capture(alloc, "'zig' 'build' 'run' '--' 'akamata-openapi' 2>/dev/null") catch null;
    if (local) |bytes| {
        if (parseEndpoints(alloc, bytes)) |routes| return routes else |_| {}
    }
    // Compatibility fallback for applications that already expose OpenAPI.
    const url = try std.fmt.allocPrint(alloc, "{s}/openapi.json", .{base_url});
    const response = am.http_client.send(alloc, .{ .method = .GET, .url = url }) catch return error.DiscoveryFailed;
    if (response.status < 200 or response.status >= 300) return error.DiscoveryFailed;
    return parseEndpoints(alloc, response.body);
}

fn parseEndpoints(alloc: std.mem.Allocator, bytes: []const u8) ![]const Endpoint {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return error.InvalidOpenApi;
    // Parsed strings and endpoint slices share the caller's arena; intentionally
    // do not deinit the parsed tree here.
    const root = parsed.value;
    if (root != .object) return error.InvalidOpenApi;
    const paths = root.object.get("paths") orelse return error.InvalidOpenApi;
    if (paths != .object) return error.InvalidOpenApi;
    var out: std.ArrayList(Endpoint) = .empty;
    var path_it = paths.object.iterator();
    while (path_it.next()) |path_entry| {
        if (path_entry.value_ptr.* != .object) continue;
        var method_it = path_entry.value_ptr.*.object.iterator();
        while (method_it.next()) |method_entry| {
            const method = parseMethod(method_entry.key_ptr.*) orelse continue;
            const operation = method_entry.value_ptr.*;
            var summary: []const u8 = "";
            var operation_id: []const u8 = "";
            if (operation == .object) {
                if (operation.object.get("summary")) |v| if (v == .string) {
                    summary = v.string;
                };
                if (operation.object.get("operationId")) |v| if (v == .string) {
                    operation_id = v.string;
                };
            }
            try out.append(alloc, .{ .method = method, .path = path_entry.key_ptr.*, .summary = summary, .operation_id = operation_id });
        }
    }
    if (out.items.len == 0) return error.NoEndpoints;
    std.mem.sort(Endpoint, out.items, {}, struct {
        fn less(_: void, a: Endpoint, b: Endpoint) bool {
            const by_path = std.mem.order(u8, a.path, b.path);
            return if (by_path == .eq) std.mem.lessThan(u8, @tagName(a.method), @tagName(b.method)) else by_path == .lt;
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

fn execute(alloc: std.mem.Allocator, state: *State) !void {
    var request_arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer request_arena_state.deinit();
    const request_arena = request_arena_state.allocator();
    const path = state.request_path;
    const url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) path else try std.fmt.allocPrint(request_arena, "{s}{s}{s}", .{ state.base_url, if (std.mem.startsWith(u8, path, "/")) "" else "/", path });
    var headers: std.ArrayList(am.http_client.Header) = .empty;
    if (state.body.len > 0) try headers.append(request_arena, .{ .name = "content-type", .value = "application/json" });
    if (state.header.len > 0) {
        const colon = std.mem.indexOfScalar(u8, state.header, ':') orelse {
            state.message = "Header must use Name: Value format.";
            return;
        };
        try headers.append(request_arena, .{
            .name = std.mem.trim(u8, state.header[0..colon], " \t"),
            .value = std.mem.trim(u8, state.header[colon + 1 ..], " \t"),
        });
    }
    const response = am.http_client.send(request_arena, .{
        .method = state.request_method,
        .url = url,
        .headers = headers.items,
        .body = state.body,
        .max_response_bytes = 8 * 1024 * 1024,
    }) catch |err| {
        state.response_status = null;
        state.response_body = try std.fmt.allocPrint(alloc, "Request failed: {s}", .{@errorName(err)});
        state.message = "Transport error. Check the server and base URL.";
        return;
    };
    state.response_status = response.status;
    state.response_body = try prettyBody(alloc, response.body);
    state.message = if (response.status >= 400) "HTTP error response received." else "Request completed.";
}

fn fillPathParams(alloc: std.mem.Allocator, state: *State) !bool {
    while (std.mem.indexOfScalar(u8, state.request_path, '{')) |open| {
        const relative_close = std.mem.indexOfScalar(u8, state.request_path[open + 1 ..], '}') orelse {
            state.message = "Malformed path parameter.";
            return false;
        };
        const close = open + 1 + relative_close;
        const name = state.request_path[open + 1 .. close];
        const label = try std.fmt.allocPrint(alloc, "Value for path parameter `{s}`", .{name});
        const value = try prompt(alloc, label, "");
        if (value.len == 0) {
            state.message = "Path parameter was left empty; request cancelled.";
            return false;
        }
        const encoded = try percentEncode(alloc, value);
        state.request_path = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ state.request_path[0..open], encoded, state.request_path[close + 1 ..] });
    }
    return true;
}

fn percentEncode(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try out.append(alloc, c) else try out.print(alloc, "%{X:0>2}", .{c});
    }
    return out.toOwnedSlice(alloc);
}

fn nextMethod(current: am.http_client.Method) am.http_client.Method {
    const methods = std.meta.tags(am.http_client.Method);
    inline for (methods, 0..) |method, i| if (method == current) return methods[(i + 1) % methods.len];
    return .GET;
}

fn prettyBody(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return alloc.dupe(u8, body);
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &out);
    defer out = aw.toArrayList();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &aw.writer);
    return aw.toOwnedSlice();
}

fn draw(state: *const State) void {
    std.debug.print("\x1b[H\x1b[2J\x1b[1;36m AKAMATA API CLIENT \x1b[0m  {s}\n", .{state.base_url});
    std.debug.print("\x1b[90m────────────────────────────────────────────────────────────────────────────────────────\x1b[0m\n", .{});
    const shown = @min(state.endpoints.len, 14);
    for (state.endpoints[0..shown], 0..) |endpoint, i| {
        const cursor = if (i == state.selected) "\x1b[30;46m>" else " ";
        std.debug.print("{s} {s: <7} {s: <34}\x1b[0m {s}\n", .{ cursor, @tagName(endpoint.method), endpoint.path, endpoint.summary });
    }
    if (state.endpoints.len > shown) std.debug.print("  … {d} more route(s)\n", .{state.endpoints.len - shown});
    std.debug.print("\x1b[90m────────────────────────────────────────────────────────────────────────────────────────\x1b[0m\n", .{});
    std.debug.print("\x1b[1mRequest\x1b[0m  {s} {s}\n", .{ @tagName(state.request_method), state.request_path });
    std.debug.print("Header   {s}\n", .{if (state.header.len == 0) "(empty — press h to edit)" else state.header});
    std.debug.print("Body     {s}\n", .{if (state.body.len == 0) "(empty — press b to edit)" else state.body});
    std.debug.print("\x1b[90m────────────────────────────────────────────────────────────────────────────────────────\x1b[0m\n", .{});
    if (state.response_status) |status| std.debug.print("\x1b[1mResponse {d}\x1b[0m\n", .{status}) else std.debug.print("\x1b[1mResponse\x1b[0m\n", .{});
    printLimited(state.response_body, 14);
    std.debug.print("\n\x1b[30;47m {s} \x1b[0m", .{state.message});
}

fn printLimited(text: []const u8, max_lines: usize) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var lines: usize = 0;
    while (it.next()) |line| : (lines += 1) {
        if (lines == max_lines) {
            std.debug.print("…\n", .{});
            break;
        }
        std.debug.print("{s}\n", .{if (line.len > 100) line[0..100] else line});
    }
}

fn prompt(alloc: std.mem.Allocator, label: []const u8, current: []const u8) ![]const u8 {
    leaveRaw();
    defer enterRaw();
    std.debug.print("\x1b[H\x1b[2J{s}\nCurrent: {s}\n> ", .{ label, current });
    var buf: [8192]u8 = undefined;
    const n_signed = posixRead(0, &buf, buf.len);
    if (n_signed <= 0) return current;
    const input = std.mem.trimEnd(u8, buf[0..@intCast(n_signed)], "\r\n");
    return alloc.dupe(u8, input);
}

fn capture(alloc: std.mem.Allocator, command: [*:0]const u8) ![]u8 {
    const file = popen(command, "r") orelse return error.DiscoveryFailed;
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = fread(&buf, 1, buf.len, file);
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    if (pclose(file) != 0) return error.DiscoveryFailed;
    return out.toOwnedSlice(alloc);
}

fn parseMethod(raw: []const u8) ?am.http_client.Method {
    inline for (std.meta.tags(am.http_client.Method)) |method| if (std.ascii.eqlIgnoreCase(raw, @tagName(method))) return method;
    return null;
}
fn enterScreen() void {
    _ = system("stty -echo -icanon min 1 time 0; printf '\\033[?1049h\\033[?25l'");
}
fn leaveScreen() void {
    _ = system("stty sane; printf '\\033[?25h\\033[?1049l'");
}
fn enterRaw() void {
    _ = system("stty -echo -icanon min 1 time 0");
}
fn leaveRaw() void {
    _ = system("stty sane");
}
fn readKey() !u8 {
    var byte: [1]u8 = undefined;
    return if (posixRead(0, &byte, 1) == 1) byte[0] else error.EndOfStream;
}

const FILE = opaque {};
extern "c" fn system(command: [*:0]const u8) c_int;
extern "c" fn read(fd: c_int, buffer: [*]u8, count: usize) isize;
const posixRead = read;
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(file: *FILE) c_int;
extern "c" fn fread(buffer: [*]u8, size: usize, count: usize, file: *FILE) usize;

test "TUI parses route metadata without an exposed endpoint" {
    const spec = "{\"paths\":{\"/notes/{id}\":{\"get\":{\"summary\":\"Show\",\"operationId\":\"showNote\"}}}}";
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const routes = try parseEndpoints(arena_state.allocator(), spec);
    try std.testing.expectEqual(@as(usize, 1), routes.len);
    try std.testing.expectEqualStrings("/notes/{id}", routes[0].path);
}
