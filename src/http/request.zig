const std = @import("std");
const status = @import("status.zig");

pub const Method = status.Method;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    raw_method: []const u8,
    path: []const u8,
    query: []const u8,
    version: []const u8,
    headers: []const Header,
    body: []const u8,
    keep_alive: bool,

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn headerEql(self: Request, name: []const u8, value: []const u8) bool {
        const v = self.header(name) orelse return false;
        return eqlIgnoreCase(v, value);
    }

    pub fn headerContains(self: Request, name: []const u8, needle: []const u8) bool {
        const v = self.header(name) orelse return false;
        return containsIgnoreCase(v, needle);
    }

    pub fn bodySlice(self: Request) []const u8 {
        return self.body;
    }
};

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
