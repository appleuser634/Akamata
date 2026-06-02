const std = @import("std");
const am = @import("akamata");
const App = @import("../app.zig").App;
const auth_mw = @import("../auth_mw.zig");

const Ctx = am.Context(App);

const ForecastBody = struct { location: []const u8 };

pub fn forecast(ctx: *Ctx) !void {
    _ = try auth_mw.requireUser(ctx);
    const body = am.json.parseLeaky(ForecastBody, ctx.arena, ctx.req.body()) catch {
        return ctx.json(.{ .error_kind = "bad_request" }, 400);
    };
    if (body.location.len == 0 or ctx.state().cfg.weather_api_key.len == 0) {
        return ctx.json(.{ .error_kind = "weather_unavailable" }, 400);
    }

    // OpenWeatherMap call. URL-encode location with our small percent encoder.
    var encoded: std.ArrayList(u8) = .empty;
    try percentEncode(ctx.arena, &encoded, body.location);

    const url = try std.fmt.allocPrint(
        ctx.arena,
        "https://api.openweathermap.org/data/2.5/weather?q={s}&appid={s}&lang=ja&units=metric",
        .{ encoded.items, ctx.state().cfg.weather_api_key },
    );

    const resp = am.http_client.send(ctx.arena, .{
        .method = .GET,
        .url = url,
    }) catch return ctx.json(.{ .error_kind = "weather_upstream_failed" }, 502);
    if (resp.status < 200 or resp.status >= 300) {
        return ctx.json(.{ .error_kind = "weather_upstream_status", .status = resp.status }, 502);
    }

    // Pass-through (clients parse the OpenWeatherMap JSON directly in the mobus client).
    try ctx.res.header("content-type", "application/json");
    ctx.status(200);
    try ctx.res.writeAll(resp.body);
}

fn percentEncode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~')
        {
            try out.append(gpa, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.append(gpa, '%');
            try out.append(gpa, hex[c >> 4]);
            try out.append(gpa, hex[c & 0xF]);
        }
    }
}
