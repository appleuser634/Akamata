const std = @import("std");

pub const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const HandshakeError = error{
    NotUpgrade,
    BadVersion,
    MissingKey,
    KeyTooLong,
    InvalidKey,
};

/// Compute Sec-WebSocket-Accept value from the client's Sec-WebSocket-Key.
/// Output buffer must be at least 28 bytes.
pub fn acceptKey(client_key: []const u8, out: []u8) HandshakeError!usize {
    if (client_key.len > 64) return HandshakeError.KeyTooLong;
    var decoded: [16]u8 = undefined;
    const trimmed = std.mem.trim(u8, client_key, " \t");
    if (trimmed.len != 24) return HandshakeError.InvalidKey;
    std.base64.standard.Decoder.decode(&decoded, trimmed) catch return HandshakeError.InvalidKey;
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(trimmed);
    sha1.update(GUID);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    const enc = std.base64.standard.Encoder;
    const need = enc.calcSize(digest.len);
    if (out.len < need) return HandshakeError.KeyTooLong;
    _ = enc.encode(out[0..need], &digest);
    return need;
}

/// Returns true if the request headers indicate a valid WebSocket upgrade.
pub fn isUpgradeRequest(
    upgrade_header: ?[]const u8,
    connection_header: ?[]const u8,
    version_header: ?[]const u8,
) bool {
    const upgrade = upgrade_header orelse return false;
    const connection = connection_header orelse return false;
    const version = version_header orelse return false;
    if (!tokenListContains(upgrade, "websocket")) return false;
    if (!tokenListContains(connection, "upgrade")) return false;
    if (!std.mem.eql(u8, std.mem.trim(u8, version, " \t"), "13")) return false;
    return true;
}

fn tokenListContains(value: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |item| if (eqlIgnoreCase(std.mem.trim(u8, item, " \t"), needle)) return true;
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}
