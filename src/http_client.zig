const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const is_native = build_options.backend == .native;

pub const HttpClientError = error{
    InvalidUrl,
    ConnectFailed,
    TlsHandshakeFailed,
    /// The peer presented no certificate, or the certificate's SAN/CN did not
    /// match the requested host. Connection aborted to prevent MITM.
    TlsCertVerifyFailed,
    WriteFailed,
    ReadFailed,
    ResponseTooLarge,
    HttpProtocolError,
    UnsupportedOnTarget,
    OutOfMemory,
};

pub const Method = enum { GET, POST, PUT, DELETE };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// Max bytes of response to accept.
    max_response_bytes: usize = 4 * 1024 * 1024,
};

pub const Response = struct {
    status: u16,
    headers_raw: []const u8,
    body: []const u8,
};

/// Issue an HTTP/HTTPS request.
/// Native: raw TCP for http://, std.crypto.tls.Client for https://.
/// Workers: uses extern fn akamata_fetch (JS-side fetch()).
pub fn send(
    arena: std.mem.Allocator,
    request: Request,
) HttpClientError!Response {
    if (is_native) {
        return nativeSend(arena, request);
    } else {
        return workersSend(arena, request);
    }
}

// =============== URL parsing ===============

const ParsedUrl = struct {
    scheme: enum { http, https },
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(url: []const u8) HttpClientError!ParsedUrl {
    var scheme: @TypeOf((@as(ParsedUrl, undefined)).scheme) = .https;
    var rest = url;
    if (std.mem.startsWith(u8, url, "https://")) {
        rest = url[8..];
        scheme = .https;
    } else if (std.mem.startsWith(u8, url, "http://")) {
        rest = url[7..];
        scheme = .http;
    } else {
        return HttpClientError.InvalidUrl;
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash];
    const path: []const u8 = if (slash == rest.len) "/" else rest[slash..];
    var host = host_port;
    var port: u16 = if (scheme == .https) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon_idx| {
        host = host_port[0..colon_idx];
        port = std.fmt.parseInt(u16, host_port[colon_idx + 1 ..], 10) catch return HttpClientError.InvalidUrl;
    }
    return .{ .scheme = scheme, .host = host, .port = port, .path = path };
}

// =============== Workers backend (JS fetch bridge) ===============

extern "akamata_http" fn akamata_fetch(
    req_ptr: [*]const u8,
    req_len: usize,
    out_ptr: *usize,
    out_len: *usize,
) i32;

fn workersSend(arena: std.mem.Allocator, request: Request) HttpClientError!Response {
    // Serialize request: METHOD\nURL\nheader1\nheader2\n\nBODY
    var serialized: std.ArrayList(u8) = .empty;
    try serialized.appendSlice(arena, @tagName(request.method));
    try serialized.append(arena, '\n');
    try serialized.appendSlice(arena, request.url);
    try serialized.append(arena, '\n');
    for (request.headers) |h| {
        try serialized.appendSlice(arena, h.name);
        try serialized.appendSlice(arena, ": ");
        try serialized.appendSlice(arena, h.value);
        try serialized.append(arena, '\n');
    }
    try serialized.append(arena, '\n');
    try serialized.appendSlice(arena, request.body);

    var out_ptr: usize = 0;
    var out_len: usize = 0;
    const rc = akamata_fetch(serialized.items.ptr, serialized.items.len, &out_ptr, &out_len);
    if (rc != 0 or out_ptr == 0) return HttpClientError.HttpProtocolError;

    const buf: [*]const u8 = @ptrFromInt(out_ptr);
    const bytes = buf[0..out_len];
    return parseResponse(arena, bytes);
}

// =============== Native backend ===============

const Io = std.Io;
const net = std.Io.net;

// === std-only TLS: OS trust-anchor bundle, lazily loaded once. =====
//
// Replaces the previous OpenSSL BIO/SSL machinery. We rely entirely on
// `std.crypto.tls.Client` and `std.crypto.Certificate.Bundle`. The CA
// bundle is fetched once from the OS trust store (macOS keychain,
// Linux /etc/ssl/certs, etc.) and reused for every TLS handshake.

const Certificate = std.crypto.Certificate;

var ca_bundle: Certificate.Bundle = .empty;
var ca_lock: std.Io.RwLock = .init;
var ca_init_flag: std.atomic.Value(u8) = .init(0);

fn initCaOnce(io: Io, gpa: std.mem.Allocator) !void {
    // 0=unloaded, 1=in_progress, 2=ready
    while (true) {
        const prev = ca_init_flag.cmpxchgWeak(0, 1, .acquire, .monotonic) orelse {
            const now = std.Io.Timestamp.now(io, .real);
            ca_bundle.rescan(gpa, io, now) catch |e| {
                ca_init_flag.store(0, .release);
                return e;
            };
            ca_init_flag.store(2, .release);
            return;
        };
        if (prev == 2) return;
        std.atomic.spinLoopHint();
    }
}

fn nativeSend(arena: std.mem.Allocator, request: Request) HttpClientError!Response {
    if (!is_native) return HttpClientError.UnsupportedOnTarget;
    const url = try parseUrl(request.url);

    // Build raw HTTP/1.1 request bytes.
    var req_buf: std.ArrayList(u8) = .empty;
    try req_buf.print(arena, "{s} {s} HTTP/1.1\r\n", .{ @tagName(request.method), url.path });
    try req_buf.print(arena, "host: {s}\r\n", .{url.host});
    try req_buf.appendSlice(arena, "connection: close\r\n");
    var has_content_length = false;
    var has_content_type = false;
    for (request.headers) |h| {
        if (eqlIgnoreCase(h.name, "content-length")) has_content_length = true;
        if (eqlIgnoreCase(h.name, "content-type")) has_content_type = true;
        try req_buf.print(arena, "{s}: {s}\r\n", .{ h.name, h.value });
    }
    if (request.body.len > 0 and !has_content_length) {
        try req_buf.print(arena, "content-length: {d}\r\n", .{request.body.len});
    }
    if (request.body.len > 0 and !has_content_type) {
        try req_buf.appendSlice(arena, "content-type: application/octet-stream\r\n");
    }
    try req_buf.appendSlice(arena, "\r\n");
    if (request.body.len > 0) try req_buf.appendSlice(arena, request.body);

    return switch (url.scheme) {
        .http => nativePlainSend(arena, url, req_buf.items, request.max_response_bytes),
        .https => nativeTlsSend(arena, url, req_buf.items, request.max_response_bytes),
    };
}

fn dialHost(io: Io, host: []const u8, port: u16) HttpClientError!net.Stream {
    // First try as a literal IP (so callers can hit raw addresses); fall
    // back to DNS via HostName.connect for proper hostnames.
    if (net.IpAddress.parse(host, port)) |literal| {
        var addr = literal;
        return net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch
            return HttpClientError.ConnectFailed;
    } else |_| {}
    const hn = net.HostName.init(host) catch return HttpClientError.ConnectFailed;
    return hn.connect(io, port, .{ .mode = .stream }) catch HttpClientError.ConnectFailed;
}

fn nativePlainSend(
    arena: std.mem.Allocator,
    url: ParsedUrl,
    request_bytes: []const u8,
    max_resp: usize,
) HttpClientError!Response {
    var io_impl: Io.Threaded = .init(arena, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var stream = try dialHost(io, url.host, url.port);
    defer stream.close(io);

    var w_buf: [4096]u8 = undefined;
    var sw = stream.writer(io, &w_buf);
    sw.interface.writeAll(request_bytes) catch return HttpClientError.WriteFailed;
    sw.interface.flush() catch return HttpClientError.WriteFailed;

    var r_buf: [4096]u8 = undefined;
    var sr = stream.reader(io, &r_buf);

    var all: std.ArrayList(u8) = .empty;
    var tmp: [4096]u8 = undefined;
    while (true) {
        var vec: [1][]u8 = .{&tmp};
        const n = sr.interface.readVec(&vec) catch break;
        if (n == 0) break;
        if (all.items.len + n > max_resp) return HttpClientError.ResponseTooLarge;
        try all.appendSlice(arena, tmp[0..n]);
    }
    return parseResponse(arena, all.items);
}

fn nativeTlsSend(
    arena: std.mem.Allocator,
    url: ParsedUrl,
    request_bytes: []const u8,
    max_resp: usize,
) HttpClientError!Response {
    if (!is_native) return HttpClientError.UnsupportedOnTarget;

    // --- TCP connect first; TLS lives on top of a raw stream socket.
    var io_impl: Io.Threaded = .init(arena, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    initCaOnce(io, arena) catch return HttpClientError.TlsHandshakeFailed;

    var stream = try dialHost(io, url.host, url.port);
    defer stream.close(io);

    // Underlying socket readers / writers. The TLS client wraps these,
    // doing handshake + record framing in user space. The socket reader
    // must hold at least one full TLS ciphertext record (min_buffer_len).
    var sock_w_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var sock_r_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var sw = stream.writer(io, &sock_w_buf);
    var sr = stream.reader(io, &sock_r_buf);

    // Buffers required by std.crypto.tls.Client itself. The TLS record
    // protocol needs room for one full ciphertext record on either side.
    var tls_w_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;
    var tls_r_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined;

    // Entropy + wall clock for the handshake (NewSessionTicket, ServerHello, ...).
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);
    const now = std.Io.Timestamp.now(io, .real);

    var client = std.crypto.tls.Client.init(&sr.interface, &sw.interface, .{
        .host = .{ .explicit = url.host },
        .ca = .{ .bundle = .{
            .gpa = arena,
            .io = io,
            .lock = &ca_lock,
            .bundle = &ca_bundle,
        } },
        .write_buffer = &tls_w_buf,
        .read_buffer = &tls_r_buf,
        .entropy = &entropy,
        .realtime_now = now,
    }) catch return HttpClientError.TlsHandshakeFailed;

    // Send the request through the TLS writer; close the write side to flush.
    client.writer.writeAll(request_bytes) catch return HttpClientError.WriteFailed;
    client.writer.flush() catch return HttpClientError.WriteFailed;
    // The TLS writer encrypts into the socket writer's buffer; we still
    // need the socket writer to drain those ciphertext bytes onto the FD.
    sw.interface.flush() catch return HttpClientError.WriteFailed;

    // Drain the response. allocRemaining streams until close_notify and
    // respects the size cap via Limit.
    const limit: std.Io.Limit = .limited(max_resp);
    const body = client.reader.allocRemaining(arena, limit) catch
        return HttpClientError.ReadFailed;
    return parseResponse(arena, body);
}

// =============== Response parsing ===============

fn parseResponse(arena: std.mem.Allocator, bytes: []const u8) HttpClientError!Response {
    const sep = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return HttpClientError.HttpProtocolError;
    const head = bytes[0..sep];
    var body = bytes[sep + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return HttpClientError.HttpProtocolError;
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next(); // HTTP/1.1
    const code_str = parts.next() orelse return HttpClientError.HttpProtocolError;
    const status = std.fmt.parseInt(u16, code_str, 10) catch return HttpClientError.HttpProtocolError;

    var chunked = false;
    var content_length: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (eqlIgnoreCase(name, "transfer-encoding") and containsIgnoreCase(value, "chunked")) {
            chunked = true;
        } else if (eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        }
    }

    if (chunked) {
        body = try decodeChunked(arena, body);
    } else if (content_length) |cl| {
        if (cl <= body.len) body = body[0..cl];
    }

    return .{
        .status = status,
        .headers_raw = head,
        .body = body,
    };
}

fn decodeChunked(arena: std.mem.Allocator, buf: []const u8) HttpClientError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < buf.len) {
        const le = std.mem.indexOfPos(u8, buf, i, "\r\n") orelse break;
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, buf[i..le], " \t"), 16) catch return HttpClientError.HttpProtocolError;
        i = le + 2;
        if (size == 0) break;
        if (i + size > buf.len) return HttpClientError.HttpProtocolError;
        try out.appendSlice(arena, buf[i .. i + size]);
        i += size + 2;
    }
    return out.toOwnedSlice(arena);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}
