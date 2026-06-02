// Shared application wiring used by both the native (`main.zig`) and the
// Workers (`worker.zig`) entry points. Keeping route registration in one
// place is how the "one handler set, two deploy targets" promise is kept.

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const auth_mw = @import("auth_mw.zig");

const auth = @import("handlers/auth.zig");
const misc = @import("handlers/misc.zig");
const friends = @import("handlers/friends.zig");
const messages = @import("handlers/messages.zig");
const devices = @import("handlers/devices.zig");
const weather = @import("handlers/weather.zig");
const rtchat = @import("handlers/rtchat.zig");
const ws_handler = @import("handlers/ws.zig");

/// Register every middleware and route on the given app. State must already
/// be initialised. Routes are identical across native and Workers; the
/// per-environment work (allocator choice, DB URL, secret source) is the
/// caller's responsibility — see main.zig / worker.zig.
pub fn registerRoutes(app: *am.App(App)) !void {
    _ = try app.useAll(am.mw.recover(App));
    _ = try app.useAll(am.mw.requestId(App));
    _ = try app.useAll(am.mw.accessLog(App, .json));
    _ = try app.useAll(auth_mw.jwtAuth());

    // === Auth ===
    _ = try app.post("/api/auth/register", auth.register);
    _ = try app.post("/api/auth/login", auth.login);
    _ = try app.get("/api/auth/login-id-available", auth.loginIdAvailable);

    // === Public / ping ===
    _ = try app.get("/api/public/ping", misc.publicPing);
    _ = try app.get("/api/ping", misc.ping);

    // === User ===
    _ = try app.post("/api/user/refresh-friend-code", misc.refreshFriendCode);

    // === Friends ===
    _ = try app.post("/api/friends/request", friends.request);
    _ = try app.post("/api/friends/respond", friends.respond);
    _ = try app.get("/api/friends", friends.list);
    _ = try app.get("/api/friends/pending", friends.pending);
    _ = try app.get("/api/friends/history", friends.history);
    _ = try app.get("/api/friends/rejected", friends.rejected);

    // === Messages ===
    _ = try app.post("/api/messages/send", messages.send);
    _ = try app.get("/api/messages/unread/count", messages.unreadCount);
    _ = try app.get("/api/friends/:id/messages", messages.listWithFriend);
    _ = try app.put("/api/messages/:id/read", messages.markRead);
    _ = try app.put("/api/friends/:id/messages/read-all", messages.markAllReadFromFriend);

    // === Devices ===
    _ = try app.post("/api/devices", devices.create);
    _ = try app.get("/api/devices", devices.list);
    _ = try app.put("/api/devices/:id", devices.update);
    _ = try app.delete("/api/devices/:id", devices.delete);

    // === RTChat ===
    _ = try app.post("/api/rtchat/call", rtchat.call);
    _ = try app.post("/api/rtchat/call/respond", rtchat.respond);
    _ = try app.post("/api/rtchat/call/end", rtchat.end);
    _ = try app.post("/api/rtchat/call/signal", rtchat.signal);
    _ = try app.get("/api/rtchat/call/status", rtchat.status);

    // === Weather ===
    _ = try app.post("/api/weather/forecast", weather.forecast);

    // === WebSocket ===
    _ = try app.ws("/api/ws", ws_handler.upgrade);
}

/// Build the per-environment `State`. Pulls every knob from the env so that
/// both deploy targets read the same config surface.
pub fn buildState(alloc: std.mem.Allocator) !App {
    if (am.backend == .native) {
        am.env.loadDotEnv(alloc, ".env") catch {};
    }

    const jwt_secret = (am.env.get(alloc, "JWT_SECRET")) orelse try alloc.dupe(u8, "your-secret-key-here");
    const db_url = (am.env.get(alloc, "DATABASE_URL")) orelse blk: {
        // Sensible default per backend: a local file on native, a Turso
        // libsql URL placeholder on Workers (which the operator must fill in).
        if (am.backend == .native) break :blk try alloc.dupe(u8, "file:mobus_data.db");
        break :blk try alloc.dupe(u8, "libsql://example.turso.io");
    };
    const weather_key = (am.env.get(alloc, "WEATHER_KEY")) orelse try alloc.dupe(u8, "");
    const mqtt_broker = (am.env.get(alloc, "MQTT_BROKER")) orelse try alloc.dupe(u8, "");
    const mqtt_client_id = (am.env.get(alloc, "MQTT_CLIENT_ID")) orelse try alloc.dupe(u8, "akamata-mobus");

    var database = try am.db.open(alloc, db_url);
    // Schema bootstrap only makes sense for SQLite (in-place file). For Turso
    // / D1 the schema is applied out-of-band via `turso db migrate` / `wrangler
    // d1 execute`.
    if (am.backend == .native and std.mem.startsWith(u8, db_url, "file:")) {
        database.execAll(@embedFile("schema.sql")) catch |e| {
            std.log.warn("schema bootstrap failed: {t}", .{e});
        };
    }

    var push_sender = am.push.Sender.init(alloc);
    if (am.backend == .native) {
        if (am.env.get(alloc, "FCM_SERVICE_ACCOUNT_PATH")) |sap| {
            if (sap.len > 0) push_sender.loadServiceAccountFromFile(sap) catch |e| {
                std.log.warn("FCM init failed: {t}", .{e});
            };
            alloc.free(sap);
        }
    }

    const Hub = @import("ws_hub.zig").Hub;
    return .{
        .gpa = alloc,
        .io = undefined,
        .db = database,
        .hub = Hub.init(alloc),
        .cfg = .{
            .jwt_secret = jwt_secret,
            .weather_api_key = weather_key,
            .mqtt_broker = mqtt_broker,
            .mqtt_client_id = mqtt_client_id,
        },
        .push = push_sender,
    };
}
