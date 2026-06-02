// Pure-Zig MQTT 3.1.1 QoS 0 publisher. Containers-only (uses TCP, no TLS).
//
// One-shot publish: each call opens a connection, sends CONNECT + PUBLISH +
// DISCONNECT, then closes. mobus_server_zig follows the same pattern; broker
// connection pooling can be added later if throughput becomes a concern.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const is_native = build_options.backend == .native;
const Io = std.Io;
const net = std.Io.net;

pub const MqError = error{
    UnsupportedOnTarget,
    InvalidBrokerUrl,
    ConnectFailed,
    WriteFailed,
    ProtocolError,
    OutOfMemory,
};

pub const Config = struct {
    /// tcp://host:port or host:port. (TLS not supported in this MVP.)
    broker: []const u8,
    client_id: []const u8 = "akamata",
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const Publisher = struct {
    gpa: std.mem.Allocator,
    cfg: Config,

    pub fn init(gpa: std.mem.Allocator, cfg: Config) Publisher {
        return .{ .gpa = gpa, .cfg = cfg };
    }

    /// Publish `payload` to `topic` at QoS 0, no retain.
    /// Returns immediately on success; the connection is closed before return.
    pub fn publish(self: *Publisher, topic: []const u8, payload: []const u8) MqError!void {
        if (!is_native) return MqError.UnsupportedOnTarget;
        const parsed = try parseBroker(self.cfg.broker);

        var io_impl: Io.Threaded = .init(self.gpa, .{});
        defer io_impl.deinit();
        const io = io_impl.io();

        var addr = net.IpAddress.resolve(io, parsed.host, parsed.port) catch return MqError.ConnectFailed;
        var stream = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return MqError.ConnectFailed;
        defer stream.close(io);

        var w_buf: [4096]u8 = undefined;
        var sw = stream.writer(io, &w_buf);
        var r_buf: [256]u8 = undefined;
        var sr = stream.reader(io, &r_buf);

        // === CONNECT ===
        var conn_pkt: std.ArrayList(u8) = .empty;
        try buildConnect(self.gpa, &conn_pkt, self.cfg);
        defer conn_pkt.deinit(self.gpa);
        sw.interface.writeAll(conn_pkt.items) catch return MqError.WriteFailed;
        sw.interface.flush() catch return MqError.WriteFailed;

        // === CONNACK (4 bytes: 0x20 0x02 flags rc) ===
        var ack: [4]u8 = undefined;
        var vec: [1][]u8 = .{&ack};
        const n = sr.interface.readVec(&vec) catch return MqError.ProtocolError;
        if (n < 4 or ack[0] != 0x20 or ack[3] != 0x00) return MqError.ProtocolError;

        // === PUBLISH (QoS 0) ===
        var pub_pkt: std.ArrayList(u8) = .empty;
        try buildPublish(self.gpa, &pub_pkt, topic, payload);
        defer pub_pkt.deinit(self.gpa);
        sw.interface.writeAll(pub_pkt.items) catch return MqError.WriteFailed;

        // === DISCONNECT ===
        sw.interface.writeAll(&.{ 0xE0, 0x00 }) catch return MqError.WriteFailed;
        sw.interface.flush() catch return MqError.WriteFailed;
    }
};

const ParsedBroker = struct { host: []const u8, port: u16 };

fn parseBroker(s: []const u8) MqError!ParsedBroker {
    var rest = s;
    if (std.mem.startsWith(u8, s, "tcp://")) rest = s[6..];
    if (std.mem.startsWith(u8, s, "mqtt://")) rest = s[7..];
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return MqError.InvalidBrokerUrl;
    const host = rest[0..colon];
    const port_str = rest[colon + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return MqError.InvalidBrokerUrl;
    if (host.len == 0) return MqError.InvalidBrokerUrl;
    return .{ .host = host, .port = port };
}

fn writeRemainingLength(list: *std.ArrayList(u8), gpa: std.mem.Allocator, n: usize) !void {
    var v = n;
    while (true) {
        var enc: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) enc |= 0x80;
        try list.append(gpa, enc);
        if (v == 0) break;
    }
}

fn writeUtf8(list: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    var len_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_bytes, @intCast(s.len), .big);
    try list.appendSlice(gpa, &len_bytes);
    try list.appendSlice(gpa, s);
}

fn buildConnect(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cfg: Config) !void {
    // Variable header: "MQTT" + level 4 + flags + keepalive
    var var_header: std.ArrayList(u8) = .empty;
    defer var_header.deinit(gpa);
    try writeUtf8(&var_header, gpa, "MQTT");
    try var_header.append(gpa, 4); // protocol level 3.1.1

    var flags: u8 = 0x02; // clean session
    if (cfg.username != null) flags |= 0x80;
    if (cfg.password != null) flags |= 0x40;
    try var_header.append(gpa, flags);
    try var_header.appendSlice(gpa, &.{ 0x00, 0x3C }); // keepalive 60s

    // Payload: client_id [, username] [, password]
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try writeUtf8(&payload, gpa, cfg.client_id);
    if (cfg.username) |u| try writeUtf8(&payload, gpa, u);
    if (cfg.password) |p| try writeUtf8(&payload, gpa, p);

    // Fixed header: 0x10 + remaining length
    try out.append(gpa, 0x10);
    try writeRemainingLength(out, gpa, var_header.items.len + payload.items.len);
    try out.appendSlice(gpa, var_header.items);
    try out.appendSlice(gpa, payload.items);
}

fn buildPublish(gpa: std.mem.Allocator, out: *std.ArrayList(u8), topic: []const u8, payload: []const u8) !void {
    try out.append(gpa, 0x30); // PUBLISH, QoS 0, no DUP, no RETAIN
    try writeRemainingLength(out, gpa, 2 + topic.len + payload.len);
    try writeUtf8(out, gpa, topic);
    try out.appendSlice(gpa, payload);
}

test "MQTT CONNECT packet encodes correctly" {
    const alloc = std.testing.allocator;
    var pkt: std.ArrayList(u8) = .empty;
    defer pkt.deinit(alloc);
    try buildConnect(alloc, &pkt, .{ .broker = "tcp://h:1", .client_id = "abc" });
    // CONNECT fixed header
    try std.testing.expectEqual(@as(u8, 0x10), pkt.items[0]);
    // Should contain "MQTT" protocol name
    try std.testing.expect(std.mem.indexOf(u8, pkt.items, "MQTT") != null);
    // Should contain client id
    try std.testing.expect(std.mem.indexOf(u8, pkt.items, "abc") != null);
}

test "MQTT PUBLISH packet encodes correctly" {
    const alloc = std.testing.allocator;
    var pkt: std.ArrayList(u8) = .empty;
    defer pkt.deinit(alloc);
    try buildPublish(alloc, &pkt, "test/topic", "hello");
    try std.testing.expectEqual(@as(u8, 0x30), pkt.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, pkt.items, "test/topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, pkt.items, "hello") != null);
}

test "parseBroker handles tcp:// scheme and bare host:port" {
    const a = try parseBroker("tcp://localhost:1883");
    try std.testing.expectEqualStrings("localhost", a.host);
    try std.testing.expectEqual(@as(u16, 1883), a.port);
    const b = try parseBroker("broker.example.com:1234");
    try std.testing.expectEqualStrings("broker.example.com", b.host);
    try std.testing.expectEqual(@as(u16, 1234), b.port);
}
