//! Schema-agnostic authenticated identity stored in an Akamata Session.
const std = @import("std");

pub const key = "__authenticated_subject";

pub fn subject(session: anytype) !?[]u8 {
    return session.get(key);
}
pub fn userId(session: anytype) !?i64 {
    const value = try subject(session) orelse return null;
    return std.fmt.parseInt(i64, value, 10) catch error.InvalidAuthenticatedSubject;
}
pub fn authenticate(session: anytype, c: anytype, value: []const u8) !void {
    try session.rotate(c);
    try session.set(key, value);
}
pub fn authenticateId(session: anytype, c: anytype, value: i64) !void {
    try authenticate(session, c, try std.fmt.allocPrint(session.arena, "{d}", .{value}));
}
pub fn logout(session: anytype, c: anytype) !void {
    try session.revoke(c);
}
