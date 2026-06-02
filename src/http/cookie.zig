// HTTP Cookie helpers: parse `Cookie:` header (request) and build
// `Set-Cookie:` header (response).
//
// We deliberately keep this simple — no double-quoted values, no domain
// expansion, no priority/partitioned attrs. If you need those, build the
// `Set-Cookie` string yourself with `c.res.header("set-cookie", ...)`.

const std = @import("std");

pub const SameSite = enum { strict, lax, none };

pub const Options = struct {
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    max_age_secs: ?i64 = null,
    expires_unix: ?i64 = null,
    http_only: bool = false,
    secure: bool = false,
    same_site: ?SameSite = null,
};

/// Build a single `Set-Cookie` header value. The returned slice is allocated
/// in `arena` and lifetime-matches the request.
pub fn build(arena: std.mem.Allocator, name: []const u8, value: []const u8, opts: Options) ![]u8 {
    try validateName(name);
    try validateValue(value);

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, name);
    try buf.append(arena, '=');
    try buf.appendSlice(arena, value);

    if (opts.path) |p| {
        try buf.appendSlice(arena, "; Path=");
        try buf.appendSlice(arena, p);
    }
    if (opts.domain) |d| {
        try buf.appendSlice(arena, "; Domain=");
        try buf.appendSlice(arena, d);
    }
    if (opts.max_age_secs) |m| {
        const s = try std.fmt.allocPrint(arena, "{d}", .{m});
        try buf.appendSlice(arena, "; Max-Age=");
        try buf.appendSlice(arena, s);
    }
    if (opts.expires_unix) |e| {
        const s = try formatHttpDate(arena, e);
        try buf.appendSlice(arena, "; Expires=");
        try buf.appendSlice(arena, s);
    }
    if (opts.http_only) try buf.appendSlice(arena, "; HttpOnly");
    if (opts.secure) try buf.appendSlice(arena, "; Secure");
    if (opts.same_site) |ss| {
        try buf.appendSlice(arena, "; SameSite=");
        try buf.appendSlice(arena, switch (ss) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        });
    }
    return buf.toOwnedSlice(arena);
}

/// Look up `name` in a raw `Cookie:` header value. Returns the first match.
pub fn parseHeader(cookie_header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], name)) {
            return trimmed[eq + 1 ..];
        }
    }
    return null;
}

const CookieValidateError = error{ InvalidCookieName, InvalidCookieValue };

fn validateName(name: []const u8) CookieValidateError!void {
    if (name.len == 0) return error.InvalidCookieName;
    for (name) |b| switch (b) {
        '0'...'9', 'a'...'z', 'A'...'Z' => {},
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return error.InvalidCookieName,
    };
}

fn validateValue(value: []const u8) CookieValidateError!void {
    // RFC 6265 cookie-octet: 0x21, 0x23–2B, 0x2D–3A, 0x3C–5B, 0x5D–7E.
    for (value) |b| switch (b) {
        ' ', '\t', '"', ',', ';', '\\', '\r', '\n', 0 => return error.InvalidCookieValue,
        else => {},
    };
}

/// RFC 7231 IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT".
fn formatHttpDate(arena: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    // Day-of-week, day-month-year-time-zone from a Unix timestamp using std.time.
    // We avoid pulling in a full timezone DB; everything stays UTC.
    const epoch_secs: u64 = if (unix_seconds < 0) 0 else @intCast(unix_seconds);
    const epoch_day = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_seconds = epoch_day.getDaySeconds();
    const year_day = epoch_day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Day-of-week: Jan 1 1970 was a Thursday (=4 if Sun=0).
    const dow_idx = @mod(@as(i64, @intCast(epoch_day.getEpochDay().day)) + 4, 7);
    const wnames = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mnames = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.allocPrint(arena, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        wnames[@intCast(dow_idx)],
        month_day.day_index + 1,
        mnames[month_day.month.numeric() - 1],
        @as(u32, year_day.year),
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

test "build minimal Set-Cookie" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const s = try build(arena_state.allocator(), "sid", "abc", .{});
    try std.testing.expectEqualStrings("sid=abc", s);
}

test "build with attributes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const s = try build(arena_state.allocator(), "sid", "abc", .{
        .path = "/",
        .max_age_secs = 3600,
        .http_only = true,
        .secure = true,
        .same_site = .lax,
    });
    try std.testing.expectEqualStrings("sid=abc; Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=Lax", s);
}

test "build rejects bad name or value" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidCookieName, build(arena_state.allocator(), "bad name", "v", .{}));
    try std.testing.expectError(error.InvalidCookieValue, build(arena_state.allocator(), "ok", "a;b", .{}));
}

test "parseHeader extracts named cookie" {
    try std.testing.expectEqualStrings("xyz", parseHeader("a=1; sid=xyz; b=2", "sid").?);
    try std.testing.expectEqualStrings("xyz", parseHeader("sid=xyz", "sid").?);
    try std.testing.expect(parseHeader("a=1; b=2", "sid") == null);
}
