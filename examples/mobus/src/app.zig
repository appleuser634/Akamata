const std = @import("std");
const am = @import("akamata");
const Hub = @import("ws_hub.zig").Hub;

pub const Config = struct {
    jwt_secret: []const u8,
    weather_api_key: []const u8 = "",
    mqtt_broker: []const u8 = "",
    mqtt_client_id: []const u8 = "akamata-mobus",
    mqtt_username: ?[]const u8 = null,
    mqtt_password: ?[]const u8 = null,
    fcm_service_account_path: ?[]const u8 = null,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    db: am.db.Db,
    hub: Hub,
    cfg: Config,
    push: am.push.Sender,
};
