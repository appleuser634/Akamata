//! Safe structured context for request/event/queue/realtime logs. Payloads and
//! credentials are deliberately absent from this type.
pub const Transport = enum { http, websocket, queue, storage, tcp, other };
pub const Backend = enum { native, workers, containers, other };

pub const Activity = struct {
    request_id: ?[]const u8 = null,
    event_id: ?[]const u8 = null,
    correlation_id: ?[]const u8 = null,
    queue_attempt: ?u16 = null,
    realtime_room: ?[]const u8 = null,
    realtime_session: ?[]const u8 = null,
    transport: Transport,
    backend: Backend,
    duration_ns: u64 = 0,
    error_code: ?[]const u8 = null,

    pub fn childEvent(self: Activity, event_id: []const u8, correlation_id: ?[]const u8) Activity {
        var child = self;
        child.event_id = event_id;
        child.correlation_id = correlation_id orelse self.request_id;
        return child;
    }
};

test "event correlation defaults to request id" {
    const a: Activity = .{ .request_id = "req", .transport = .http, .backend = .native };
    const event = a.childEvent("event", null);
    try @import("std").testing.expectEqualStrings("req", event.correlation_id.?);
}
