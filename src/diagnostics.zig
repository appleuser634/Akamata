//! Stable, structured diagnostics for framework and application tooling.
const std = @import("std");

pub const Severity = enum { info, warning, @"error" };
pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    hint: ?[]const u8 = null,
    file: ?[]const u8 = null,
};

pub fn writeText(d: Diagnostic, w: *std.Io.Writer) !void {
    try w.print("{s}[{s}]: {s}", .{ @tagName(d.severity), d.code, d.message });
    if (d.file) |file| try w.print(" ({s})", .{file});
    if (d.hint) |hint| try w.print("\n  hint: {s}", .{hint});
    try w.writeByte('\n');
}

pub fn writeJson(d: Diagnostic, w: *std.Io.Writer) !void {
    try std.json.Stringify.value(d, .{}, w);
}
