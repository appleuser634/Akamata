const std = @import("std");
const am = @import("akamata");

const App = struct { counter: std.atomic.Value(u32) = .init(0) };

fn helloHandler(ctx: *am.Ctx(App)) !void {
    _ = ctx.app.counter.fetchAdd(1, .seq_cst);
    try ctx.json(200, .{ .greeting = "hello" });
}

fn echoHandler(ctx: *am.Ctx(App)) !void {
    try ctx.res.header("content-type", "text/plain; charset=utf-8");
    try ctx.res.writeAll(ctx.req.bodySlice());
}

fn streamHandler(ctx: *am.Ctx(App)) !void {
    const w = try ctx.res.startStream(.{ .content_type = "text/plain; charset=utf-8" });
    try w.writeAll("chunk-one");
    try w.flush();
    try w.writeAll("chunk-two");
    try w.flush();
    try w.writeAll("chunk-three");
    try w.flush();
}

const router = am.Router(App).build(&.{
    am.Router(App).get("/hello", helloHandler),
    am.Router(App).post("/echo", echoHandler),
    am.Router(App).get("/stream", streamHandler),
});

test "server roundtrips a GET request" {
    const alloc = std.testing.allocator;

    var io_impl: std.Io.Threaded = .init(alloc, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var app: App = .{};

    // Bind ephemeral port for the test (use a well-known high port to keep this
    // hermetic on a developer box; if it's in use, the test will fail explicitly).
    const port: u16 = 18180;
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;

    var server = try am.Server(App).init(alloc, io, &app, .{
        .address = addr,
        .router = router,
        .accept_thread_count = 1,
    });
    defer server.deinit();

    const t = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.requestShutdown();
        t.join();
    }

    std.Io.sleep(io, .fromMilliseconds(80), .awake) catch {};

    // Connect via std.Io.net.IpAddress.connect
    var connect_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var client_stream = try std.Io.net.IpAddress.connect(&connect_addr, io, .{ .mode = .stream });
    defer client_stream.close(io);

    var w_buf: [1024]u8 = undefined;
    var sw = client_stream.writer(io, &w_buf);
    const w = &sw.interface;
    try w.writeAll("GET /hello HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n");
    try w.flush();

    var r_buf: [4096]u8 = undefined;
    var sr = client_stream.reader(io, &r_buf);
    const r = &sr.interface;

    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(alloc);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&tmp) catch break;
        if (n == 0) break;
        try collected.appendSlice(alloc, tmp[0..n]);
    }
    const resp = collected.items;

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"greeting\":\"hello\"") != null);
    try std.testing.expectEqual(@as(u32, 1), app.counter.load(.seq_cst));
}

fn runServer(server: *am.Server(App)) void {
    server.run() catch {};
}

test "server streams chunked response" {
    const alloc = std.testing.allocator;

    var io_impl: std.Io.Threaded = .init(alloc, .{});
    defer io_impl.deinit();
    const io = io_impl.io();

    var app: App = .{};
    const port: u16 = 18181;
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;

    var server = try am.Server(App).init(alloc, io, &app, .{
        .address = addr,
        .router = router,
        .accept_thread_count = 1,
    });
    defer server.deinit();

    const t = try std.Thread.spawn(.{}, runServer, .{&server});
    defer {
        server.requestShutdown();
        t.join();
    }

    std.Io.sleep(io, .fromMilliseconds(80), .awake) catch {};

    var connect_addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var client_stream = try std.Io.net.IpAddress.connect(&connect_addr, io, .{ .mode = .stream });
    defer client_stream.close(io);

    var w_buf: [256]u8 = undefined;
    var sw = client_stream.writer(io, &w_buf);
    try sw.interface.writeAll("GET /stream HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n");
    try sw.interface.flush();

    var r_buf: [4096]u8 = undefined;
    var sr = client_stream.reader(io, &r_buf);
    var collected: std.ArrayList(u8) = .empty;
    defer collected.deinit(alloc);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = sr.interface.readSliceShort(&tmp) catch break;
        if (n == 0) break;
        try collected.appendSlice(alloc, tmp[0..n]);
    }
    const resp = collected.items;

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "transfer-encoding: chunked") != null);
    // 9-byte first chunk = "9\r\nchunk-one\r\n"
    try std.testing.expect(std.mem.indexOf(u8, resp, "9\r\nchunk-one\r\n") != null);
    // Terminator
    try std.testing.expect(std.mem.endsWith(u8, resp, "0\r\n\r\n"));
}
