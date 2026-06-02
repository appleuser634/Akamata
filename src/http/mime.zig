const std = @import("std");

pub fn fromExt(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
    const ext = path[dot + 1 ..];
    if (eqlAscii(ext, "html") or eqlAscii(ext, "htm")) return "text/html; charset=utf-8";
    if (eqlAscii(ext, "js") or eqlAscii(ext, "mjs")) return "application/javascript; charset=utf-8";
    if (eqlAscii(ext, "css")) return "text/css; charset=utf-8";
    if (eqlAscii(ext, "json")) return "application/json";
    if (eqlAscii(ext, "txt")) return "text/plain; charset=utf-8";
    if (eqlAscii(ext, "png")) return "image/png";
    if (eqlAscii(ext, "jpg") or eqlAscii(ext, "jpeg")) return "image/jpeg";
    if (eqlAscii(ext, "svg")) return "image/svg+xml";
    if (eqlAscii(ext, "ico")) return "image/x-icon";
    if (eqlAscii(ext, "wasm")) return "application/wasm";
    return "application/octet-stream";
}

fn eqlAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}
