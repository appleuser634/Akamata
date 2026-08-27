//! Minimal DB-backed idempotency claims. No transaction emulation is used.
const std = @import("std");
const db = @import("db/db.zig");
const crypto = @import("crypto/util.zig");

pub const Result = enum { claimed, duplicate, key_reused };

pub fn validateKey(key: []const u8) !void {
    if (key.len < 8 or key.len > 128) return error.InvalidIdempotencyKey;
    for (key) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return error.InvalidIdempotencyKey;
}

pub fn requestHash(method: []const u8, path: []const u8, body: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(method);
    hasher.update("\n");
    hasher.update(path);
    hasher.update("\n");
    hasher.update(body);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn ensureTable(database: db.Db) !void {
    try database.exec("CREATE TABLE IF NOT EXISTS akamata_idempotency (key TEXT PRIMARY KEY, request_hash TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (unixepoch()))");
}

/// Atomic on SQLite/D1/Turso: the claim is one INSERT ... ON CONFLICT.
pub fn claim(database: db.Db, key: []const u8, hash: []const u8) !Result {
    try validateKey(key);
    if (hash.len != 64) return error.InvalidRequestHash;
    var insert = try database.prepare("INSERT INTO akamata_idempotency (key, request_hash) VALUES (?, ?) ON CONFLICT(key) DO NOTHING RETURNING key");
    defer insert.deinit();
    try insert.bindAll(.{ key, hash });
    if ((try insert.step()) == .row) return .claimed;
    var existing = try database.prepare("SELECT request_hash FROM akamata_idempotency WHERE key = ?");
    defer existing.deinit();
    try existing.bindAll(.{key});
    if ((try existing.step()) != .row) return error.IdempotencyStateLost;
    return if (crypto.timingSafeEqual(try existing.columnText(0), hash)) .duplicate else .key_reused;
}

test "idempotency key and request hash" {
    try validateKey("request-1234");
    try std.testing.expectError(error.InvalidIdempotencyKey, validateKey("short"));
    try std.testing.expectEqual(requestHash("POST", "/x", "{}"), requestHash("POST", "/x", "{}"));
}
