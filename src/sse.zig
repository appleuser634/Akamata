//! Server-Sent Events (text/event-stream) on top of chunked streaming.
//!
//! Usage from a handler:
//!
//!     pub fn ticks(c: *Ctx) !void {
//!         var s = try am.sse.open(c);
//!         var i: u32 = 0;
//!         while (i < 10) : (i += 1) {
//!             try s.send(.{ .event = "tick", .data = "{\"i\":42}" });
//!             std.Thread.sleep(1 * std.time.ns_per_s);
//!         }
//!     }
//!
//! Multi-line `data` is automatically split into multiple `data:` lines per
//! the EventSource spec.

const std = @import("std");
const Writer = std.Io.Writer;
const ChunkedWriter = @import("http/chunked.zig").ChunkedWriter;

pub const Event = struct {
    /// Optional event type. Default is the unnamed event (just `data:`).
    event: ?[]const u8 = null,
    /// Required data payload. May contain newlines — they're rewritten
    /// into multiple `data:` lines as required by the SSE wire format.
    data: []const u8,
    /// Optional message id. Set to enable client-side `Last-Event-ID`
    /// reconnection.
    id: ?[]const u8 = null,
    /// Optional retry hint (ms) for the client EventSource.
    retry: ?u32 = null,
};

pub const Sse = struct {
    /// The chunked HTTP writer. Holding the concrete type (not just a
    /// generic `*Writer`) lets us call `flushDownstream` so each event
    /// reaches the FD without waiting for the socket writer's 4 KB
    /// buffer to fill.
    cw: *ChunkedWriter,

    pub fn send(self: *Sse, event: Event) !void {
        const w = &self.cw.writer;
        if (event.event) |e| try w.print("event: {s}\n", .{e});
        if (event.id) |i| try w.print("id: {s}\n", .{i});
        if (event.retry) |r| try w.print("retry: {d}\n", .{r});

        // Split data on '\n' so multi-line payloads survive intact.
        var rest: []const u8 = event.data;
        while (true) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            if (nl) |i| {
                try w.print("data: {s}\n", .{rest[0..i]});
                rest = rest[i + 1 ..];
            } else {
                try w.print("data: {s}\n", .{rest});
                break;
            }
        }
        try w.writeAll("\n");
        // Push the encoded chunk all the way to the FD.
        try self.cw.flushDownstream();
    }

    /// Send a heartbeat comment. Useful for keeping idle connections alive
    /// through proxies that drop "silent" streams after 30-60s.
    pub fn heartbeat(self: *Sse) !void {
        try self.cw.writer.writeAll(": keepalive\n\n");
        try self.cw.flushDownstream();
    }
};

/// Open an SSE stream. Sets the appropriate Content-Type and disables any
/// proxy buffering, then starts a chunked response.
pub fn open(ctx: anytype) !Sse {
    // X-Accel-Buffering: no is the nginx/Cloudflare opt-out for buffered
    // streaming. cache-control: no-cache prevents intermediate caches from
    // breaking the long-lived response.
    try ctx.res.header("cache-control", "no-cache");
    try ctx.res.header("x-accel-buffering", "no");
    _ = try ctx.res.startStream(.{ .content_type = "text/event-stream" });
    // startStream populates res.streaming with the ChunkedWriter we need.
    return .{ .cw = ctx.res.streaming.? };
}
