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
    manual_mode: bool = false,
    viewport: TerminalSize = .{},
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
    enterScreen();
    defer leaveScreen();
    std.debug.print("\x1b[H\x1b[2J\x1b[1;36m AKAMATA API CLIENT \x1b[0m\n\nDiscovering endpoints…\n", .{});
    var endpoints = discover(arena, base_url) catch &.{};
    const manual_mode = endpoints.len == 0;
    if (manual_mode) endpoints = try arena.dupe(Endpoint, &.{.{ .method = .GET, .path = "/", .summary = "Manual request", .operation_id = "" }});

    var state: State = .{
        .endpoints = endpoints,
        .base_url = base_url,
        .request_method = endpoints[0].method,
        .request_path = endpoints[0].path,
        .manual_mode = manual_mode,
        .viewport = terminalSize(arena),
        .message = if (manual_mode) "Manual mode: no application metadata found in this directory." else "Ready. Select an endpoint and press Enter.",
    };
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
            'g' => {
                state.selected = 0;
                state.request_method = state.endpoints[0].method;
                state.request_path = state.endpoints[0].path;
            },
            'G' => {
                state.selected = state.endpoints.len - 1;
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
                state.viewport = terminalSize(arena);
                const refreshed = discover(arena, state.base_url) catch &.{};
                if (refreshed.len > 0) {
                    state.endpoints = refreshed;
                    state.selected = 0;
                    state.request_method = refreshed[0].method;
                    state.request_path = refreshed[0].path;
                    state.manual_mode = false;
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
    // Only invoke the runner when this application explicitly implements the
    // protocol. Running an arbitrary `zig build run` could start a web server
    // and block the TUI forever (notably from the Akamata framework repo).
    if (supportsLocalInspection()) {
        const local = capture(alloc, "'zig' 'build' 'run' '--' 'akamata-openapi' 2>/dev/null") catch null;
        if (local) |bytes| {
            if (parseEndpoints(alloc, bytes)) |routes| return routes else |_| {}
        }
    }
    // Existing applications and repository examples may predate the runner.
    // Their literal route registrations are still useful and require neither
    // a running server nor a public discovery endpoint.
    if (discoverFromSource(alloc)) |routes| return routes else |_| {}
    // Compatibility fallback for applications that already expose OpenAPI.
    const url = try std.fmt.allocPrint(alloc, "{s}/openapi.json", .{base_url});
    const response = am.http_client.send(alloc, .{ .method = .GET, .url = url }) catch return error.DiscoveryFailed;
    if (response.status < 200 or response.status >= 300) return error.DiscoveryFailed;
    return parseEndpoints(alloc, response.body);
}

fn discoverFromSource(alloc: std.mem.Allocator) ![]const Endpoint {
    // A framework/library checkout can also have a src/ tree containing route
    // helper implementations. Require an application entry point so those
    // internals are never mistaken for user endpoints.
    var main_buf: [2 * 1024 * 1024]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = std.Io.Dir.cwd().readFile(io, "src/main.zig", &main_buf) catch return error.SourceDiscoveryUnavailable;
    const files = capture(alloc, "find 'src' -type f -name '*.zig' 2>/dev/null") catch return error.SourceDiscoveryUnavailable;
    var out: std.ArrayList(Endpoint) = .empty;
    var file_it = std.mem.tokenizeAny(u8, files, "\r\n");
    while (file_it.next()) |path| {
        if (std.mem.indexOf(u8, path, "test") != null) continue;
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024)) catch continue;
        try parseSourceRoutes(alloc, source, path, &out);
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

fn parseSourceRoutes(alloc: std.mem.Allocator, source: []const u8, file_path: []const u8, out: *std.ArrayList(Endpoint)) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
        var method: ?am.http_client.Method = null;
        var search_from: usize = 0;
        if (std.mem.indexOf(u8, line, ".endpoint(.")) |at| {
            const method_start = at + ".endpoint(.".len;
            const method_end = std.mem.indexOfScalarPos(u8, line, method_start, ',') orelse continue;
            method = parseMethod(line[method_start..method_end]);
            search_from = method_end + 1;
        } else {
            const registrations = [_]struct { marker: []const u8, method: am.http_client.Method }{
                .{ .marker = ".get(", .method = .GET },
                .{ .marker = ".head(", .method = .HEAD },
                .{ .marker = ".post(", .method = .POST },
                .{ .marker = ".put(", .method = .PUT },
                .{ .marker = ".delete(", .method = .DELETE },
                .{ .marker = ".patch(", .method = .PATCH },
                .{ .marker = ".options(", .method = .OPTIONS },
            };
            for (registrations) |registration| {
                if (std.mem.indexOf(u8, line, registration.marker)) |at| {
                    method = registration.method;
                    search_from = at + registration.marker.len;
                }
            }
        }
        const resolved_method = method orelse continue;
        const quote = std.mem.indexOfScalarPos(u8, line, search_from, '"') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, line, quote + 1, '"') orelse continue;
        const raw_path = line[quote + 1 .. close];
        if (raw_path.len == 0 or raw_path[0] != '/') continue;
        const path = try normalizeRoutePath(alloc, raw_path);
        var duplicate = false;
        for (out.items) |existing| {
            if (existing.method == resolved_method and std.mem.eql(u8, existing.path, path)) duplicate = true;
        }
        if (duplicate) continue;
        try out.append(alloc, .{
            .method = resolved_method,
            .path = path,
            .summary = try std.fmt.allocPrint(alloc, "source · {s}", .{file_path}),
            .operation_id = "",
        });
    }
}

fn normalizeRoutePath(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var segments = std.mem.splitScalar(u8, raw, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (!first) try out.append(alloc, '/');
        first = false;
        if (std.mem.startsWith(u8, segment, ":")) {
            try out.append(alloc, '{');
            try out.appendSlice(alloc, segment[1..]);
            try out.append(alloc, '}');
        } else try out.appendSlice(alloc, segment);
    }
    return out.toOwnedSlice(alloc);
}

fn supportsLocalInspection() bool {
    var source_buf: [2 * 1024 * 1024]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const source = std.Io.Dir.cwd().readFile(io, "src/main.zig", &source_buf) catch return false;
    return hasInspectionMarker(source);
}

fn hasInspectionMarker(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "akamata-openapi") != null;
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
    const viewport = state.viewport;
    const width = @max(@as(usize, viewport.cols), 60);
    const height = @max(@as(usize, viewport.rows), 18);
    const list_height = @min(state.endpoints.len, @max(@as(usize, 3), @min(@as(usize, 12), height / 3)));
    const start = if (state.selected >= list_height) state.selected - list_height + 1 else 0;
    const response_lines = @max(@as(usize, 3), height -| list_height -| 12);

    std.debug.print("\x1b[H\x1b[2J\x1b[1;36m AKAMATA API CLIENT \x1b[0m  {s}  ", .{state.base_url});
    if (state.manual_mode) std.debug.print("\x1b[33m[MANUAL]\x1b[0m\n", .{}) else std.debug.print("\x1b[32m[DISCOVERED]\x1b[0m\n", .{});
    separator(width);
    std.debug.print("\x1b[1m Endpoints\x1b[0m  {d} route(s)  \x1b[90m↑/↓ or j/k to select · g/G first/last\x1b[0m\n", .{state.endpoints.len});
    for (state.endpoints[start .. start + list_height], start..) |endpoint, i| printEndpoint(endpoint, i == state.selected, width);
    separator(width);
    std.debug.print("\x1b[1m Request\x1b[0m   ", .{});
    printMethod(state.request_method);
    std.debug.print(" {s}\n", .{truncate(state.request_path, width -| 20)});
    std.debug.print(" Header    {s}\n", .{truncate(if (state.header.len == 0) "—" else state.header, width -| 12)});
    std.debug.print(" Body      {s}\n", .{truncate(if (state.body.len == 0) "—" else state.body, width -| 12)});
    separator(width);
    if (state.response_status) |status| {
        const color = if (status < 300) "\x1b[32m" else if (status < 400) "\x1b[36m" else "\x1b[31m";
        std.debug.print("\x1b[1m Response\x1b[0m   {s}{d}\x1b[0m\n", .{ color, status });
    } else std.debug.print("\x1b[1m Response\x1b[0m\n", .{});
    printLimited(state.response_body, response_lines, width);
    std.debug.print("\x1b[{d};1H\x1b[2K\x1b[90m{s}\x1b[0m", .{ height - 1, truncate(state.message, width) });
    const shortcuts = if (width < 100)
        " ↑↓ select  Enter send  m method  e path  h header  b body  q quit "
    else
        " ↑↓ select  Enter send  m method  e path  h header  b body  u URL  r reload  ? help  q quit ";
    std.debug.print("\x1b[{d};1H\x1b[7m\x1b[2K{s}\x1b[0m", .{ height, shortcuts });
}

fn printEndpoint(endpoint: Endpoint, selected: bool, width: usize) void {
    if (selected) std.debug.print("\x1b[30;46m", .{});
    std.debug.print("{s} ", .{if (selected) ">" else " "});
    printMethod(endpoint.method);
    const path_width = @min(@as(usize, 38), width / 2);
    const shown_path = truncate(endpoint.path, path_width);
    std.debug.print(" {s}", .{shown_path});
    for (shown_path.len..path_width) |_| std.debug.print(" ", .{});
    std.debug.print("  {s}", .{truncate(endpoint.summary, width -| (path_width + 14))});
    std.debug.print("\x1b[K\x1b[0m\n", .{});
}

fn printMethod(method: am.http_client.Method) void {
    const color = switch (method) {
        .GET, .HEAD => "\x1b[32m",
        .POST => "\x1b[33m",
        .PUT, .PATCH => "\x1b[34m",
        .DELETE => "\x1b[31m",
        .OPTIONS => "\x1b[35m",
    };
    std.debug.print("{s}{s: <7}\x1b[0m", .{ color, @tagName(method) });
}

fn printLimited(text: []const u8, max_lines: usize, width: usize) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var lines: usize = 0;
    while (it.next()) |line| : (lines += 1) {
        if (lines == max_lines) {
            std.debug.print("…\n", .{});
            break;
        }
        std.debug.print(" {s}\n", .{truncate(line, width -| 2)});
    }
}

fn truncate(text: []const u8, width: usize) []const u8 {
    return if (text.len > width) text[0..width] else text;
}

fn separator(width: usize) void {
    std.debug.print("\x1b[90m", .{});
    for (0..width) |_| std.debug.print("─", .{});
    std.debug.print("\x1b[0m\n", .{});
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
    if (posixRead(0, &byte, 1) != 1) return error.EndOfStream;
    if (byte[0] != 0x1b) return byte[0];
    var sequence: [2]u8 = undefined;
    if (posixRead(0, &sequence, 2) != 2 or sequence[0] != '[') return 0x1b;
    return switch (sequence[1]) {
        'A' => 'k',
        'B' => 'j',
        else => 0x1b,
    };
}

const TerminalSize = struct { rows: u16 = 24, cols: u16 = 100 };
fn terminalSize(alloc: std.mem.Allocator) TerminalSize {
    const output = capture(alloc, "stty size 2>/dev/null") catch return .{};
    var parts = std.mem.tokenizeAny(u8, output, " \t\r\n");
    const rows = std.fmt.parseInt(u16, parts.next() orelse return .{}, 10) catch return .{};
    const cols = std.fmt.parseInt(u16, parts.next() orelse return .{}, 10) catch return .{};
    if (rows == 0 or cols == 0) return .{};
    return .{ .rows = rows, .cols = cols };
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

test "inspection runner is only used by applications that opt in" {
    try std.testing.expect(hasInspectionMarker("if (arg == \"akamata-openapi\") {}"));
    try std.testing.expect(!hasInspectionMarker("pub fn main() void {}"));
}

test "source discovery parses typed and bare route registrations" {
    const source =
        \\_ = try app.endpoint(.PATCH, "/tasks/:id", update, am.openapi.Spec(.{}));
        \\_ = try app.get("/health", health);
        \\// _ = try app.delete("/commented", nope);
    ;
    var list: std.ArrayList(Endpoint) = .empty;
    defer list.deinit(std.testing.allocator);
    try parseSourceRoutes(std.testing.allocator, source, "src/setup.zig", &list);
    defer for (list.items) |item| {
        std.testing.allocator.free(item.path);
        std.testing.allocator.free(item.summary);
    };
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("/tasks/{id}", list.items[0].path);
}
