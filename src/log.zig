const std = @import("std");
pub const scope = std.log.scoped(.akamata);

pub fn info(comptime fmt: []const u8, args: anytype) void {
    scope.info(fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    scope.warn(fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    scope.err(fmt, args);
}
