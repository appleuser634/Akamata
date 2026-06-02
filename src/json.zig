const std = @import("std");

pub const ParseError = error{ Invalid, OutOfMemory };

/// Lenient JSON parse — unknown fields are dropped, duplicate fields keep the
/// last value. Suitable for user-supplied request bodies where forward/back-
/// ward compatibility matters more than catching typos.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    });
}

/// Strict JSON parse — rejects unknown fields and duplicate fields. Use for
/// security-relevant inputs (JWT claims, RBAC payloads) where ignoring an
/// extra field could silently mask a mass-assignment attempt.
pub fn parseLeakyStrict(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    });
}

pub fn stringify(value: anytype, writer: *std.Io.Writer) !void {
    // Comptime-specialised fast path. For supported shapes (struct, slice,
    // int, float, bool, optional, enum, null) we generate straight-line
    // emission code per call site, no reflection at runtime. Anything else
    // (unions other than optional, fn ptrs, etc.) falls back to the std
    // serialiser via `appendValue`.
    try appendValue(@TypeOf(value), value, writer);
}

/// Recursive comptime emitter. Handles the type shapes the framework uses
/// for handler responses; falls back to `std.json.Stringify.value` for the
/// long tail.
pub fn appendValue(comptime T: type, value: T, w: *std.Io.Writer) !void {
    if (T == []const u8 or T == []u8) {
        return appendStringLiteral(value, w);
    }
    const info = @typeInfo(T);
    switch (info) {
        .void => try w.writeAll("null"),
        .null => try w.writeAll("null"),
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => {
            // Format directly into a small stack buffer; up to 24 chars for i64.
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
            try w.writeAll(s);
        },
        .float, .comptime_float => {
            // Floats need more digits; 32 bytes covers everything finite.
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
            try w.writeAll(s);
        },
        .optional => {
            if (value) |v| try appendValue(@TypeOf(v), v, w) else try w.writeAll("null");
        },
        .@"enum" => {
            // Enums become their tag name as a JSON string. Models that
            // need a different mapping should use `__schema.enums` on the
            // model side; that translation is handled before reaching here.
            try w.writeByte('"');
            try escapeAscii(@tagName(value), w);
            try w.writeByte('"');
        },
        .pointer => |p| {
            if (p.size == .slice) {
                if (p.child == u8) return appendStringLiteral(value, w);
                try w.writeByte('[');
                for (value, 0..) |item, i| {
                    if (i > 0) try w.writeByte(',');
                    try appendValue(@TypeOf(item), item, w);
                }
                try w.writeByte(']');
                return;
            }
            if (p.size == .one) {
                return appendValue(p.child, value.*, w);
            }
            // Unsupported pointer shape — defer to std.
            return std.json.Stringify.value(value, .{}, w);
        },
        .array => |a| {
            if (a.child == u8) return appendStringLiteral(&value, w);
            try w.writeByte('[');
            inline for (value, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try appendValue(@TypeOf(item), item, w);
            }
            try w.writeByte(']');
        },
        .@"struct" => |s| {
            try w.writeByte('{');
            comptime var first = true;
            inline for (s.fields) |f| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeByte('"');
                try escapeAscii(f.name, w);
                try w.writeAll("\":");
                try appendValue(f.type, @field(value, f.name), w);
            }
            try w.writeByte('}');
        },
        else => return std.json.Stringify.value(value, .{}, w),
    }
}

/// Emit `"…"` with JSON escaping. We hand-roll the common cases (no per-byte
/// branch into std) since this dominates handler hot paths.
fn appendStringLiteral(s: []const u8, w: *std.Io.Writer) !void {
    try w.writeByte('"');
    try escapeJsonString(s, w);
    try w.writeByte('"');
}

fn escapeJsonString(s: []const u8, w: *std.Io.Writer) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        // Fast path: ASCII printable that needs no escape.
        if (c >= 0x20 and c != '"' and c != '\\') continue;

        if (i > start) try w.writeAll(s[start..i]);
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            8 => try w.writeAll("\\b"),
            12 => try w.writeAll("\\f"),
            else => {
                // Other control chars → \u00XX
                var buf: [6]u8 = undefined;
                const out = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try w.writeAll(out);
            },
        }
        start = i + 1;
    }
    if (start < s.len) try w.writeAll(s[start..]);
}

/// Ascii-only escape for field names (no Unicode in our generated keys).
fn escapeAscii(s: []const u8, w: *std.Io.Writer) !void {
    return escapeJsonString(s, w);
}

pub fn allocStringify(arena: std.mem.Allocator, value: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    const list = aw.toArrayList();
    return list.items;
}
