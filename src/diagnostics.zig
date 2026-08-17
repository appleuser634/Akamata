//! Stable, structured diagnostics for framework and application tooling.
const std = @import("std");

pub const Severity = enum { info, warning, @"error" };
pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    hint: ?[]const u8 = null,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
    context: ?[]const u8 = null,
};

pub fn writeText(d: Diagnostic, w: *std.Io.Writer) !void {
    try w.print("{s}[{s}]: {s}", .{ @tagName(d.severity), d.code, d.message });
    if (d.file) |file| {
        try w.print(" ({s}", .{file});
        if (d.line) |line| try w.print(":{d}", .{line});
        if (d.column) |column| try w.print(":{d}", .{column});
        try w.writeAll(")");
    }
    if (d.context) |context_text| try w.print("\n  {s}", .{context_text});
    if (d.hint) |hint| try w.print("\n  hint: {s}", .{hint});
    try w.writeByte('\n');
}

pub const Problem = struct {
    type: []const u8 = "about:blank",
    title: []const u8,
    status: u16,
    detail: []const u8,
    instance: ?[]const u8 = null,
    code: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

pub fn writeJson(d: Diagnostic, w: *std.Io.Writer) !void {
    try std.json.Stringify.value(d, .{}, w);
}
