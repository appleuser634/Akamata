const std = @import("std");
const frame = @import("frame.zig");
const handshake = @import("handshake.zig");
// (Legacy Ctx import dropped — upgrade() now uses anytype.)
const res_mod = @import("../http/response.zig");

const Io = std.Io;
const net = std.Io.net;

pub const UpgradeOptions = struct {
    max_message_bytes: usize = 64 * 1024,
    read_buffer_bytes: usize = 8 * 1024,
};

pub const Message = struct {
    opcode: frame.Opcode,
    payload: []u8,
};

pub const ReadError = error{
    ClosedByPeer,
    InvalidFrame,
    PayloadTooLarge,
    ReadFailed,
    OutOfMemory,
    UnsupportedReservedBits,
    BufferTooSmall,
    WriteFailed,
};

/// Single WebSocket connection. Holds an owned read buffer and reuses the
/// underlying TCP stream. Synchronization on the send path is a tiny atomic
/// spinlock — works because the broadcast path takes a snapshot under the
/// hub's own lock and writes are short.
pub const Conn = struct {
    gpa: std.mem.Allocator,
    stream: net.Stream,
    io: Io,
    write_mutex: @import("../sync.zig").Mutex = .{},
    recv_buf: std.ArrayList(u8) = .empty,
    max_payload: usize = 64 * 1024,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, stream: net.Stream, io: Io, max_payload: usize) Conn {
        return .{
            .gpa = gpa,
            .stream = stream,
            .io = io,
            .max_payload = max_payload,
            .write_mutex = @import("../sync.zig").Mutex.init(),
        };
    }

    pub fn deinit(self: *Conn) void {
        self.recv_buf.deinit(self.gpa);
        if (!self.closed.swap(true, .seq_cst)) {
            self.stream.close(self.io);
        }
        self.write_mutex.deinit();
    }

    pub fn isClosed(self: *Conn) bool {
        return self.closed.load(.seq_cst);
    }

    fn lockWrite(self: *Conn) void {
        self.write_mutex.lock();
    }
    fn unlockWrite(self: *Conn) void {
        self.write_mutex.unlock();
    }

    pub fn sendText(self: *Conn, payload: []const u8) !void {
        return self.send(.text, payload);
    }

    pub fn sendBinary(self: *Conn, payload: []const u8) !void {
        return self.send(.binary, payload);
    }

    pub fn close(self: *Conn, code: u16, reason: []const u8) void {
        var buf: [128]u8 = undefined;
        const blen = @min(reason.len, buf.len - 2);
        std.mem.writeInt(u16, buf[0..2], code, .big);
        @memcpy(buf[2 .. 2 + blen], reason[0..blen]);
        self.send(.close, buf[0 .. 2 + blen]) catch {};
        if (!self.closed.swap(true, .seq_cst)) self.stream.close(self.io);
    }

    fn send(self: *Conn, op: frame.Opcode, payload: []const u8) !void {
        if (self.closed.load(.seq_cst)) return ReadError.ClosedByPeer;
        var h_buf: [14]u8 = undefined;
        var pos: usize = 0;
        h_buf[0] = 0x80 | @as(u8, @intFromEnum(op));
        pos = 1;
        if (payload.len < 126) {
            h_buf[1] = @intCast(payload.len);
            pos = 2;
        } else if (payload.len <= 0xFFFF) {
            h_buf[1] = 126;
            std.mem.writeInt(u16, h_buf[2..4], @intCast(payload.len), .big);
            pos = 4;
        } else {
            h_buf[1] = 127;
            std.mem.writeInt(u64, h_buf[2..10], @intCast(payload.len), .big);
            pos = 10;
        }

        self.lockWrite();
        defer self.unlockWrite();

        var w_buf: [256]u8 = undefined;
        var sw = self.stream.writer(self.io, &w_buf);
        const w: *Io.Writer = &sw.interface;
        w.writeAll(h_buf[0..pos]) catch return ReadError.WriteFailed;
        if (payload.len > 0) w.writeAll(payload) catch return ReadError.WriteFailed;
        w.flush() catch return ReadError.WriteFailed;
    }

    pub fn readMessage(self: *Conn, arena: std.mem.Allocator) ReadError!Message {
        var assembled: std.ArrayList(u8) = .empty;
        defer assembled.deinit(self.gpa);
        var first_opcode: ?frame.Opcode = null;

        outer: while (true) {
            const fr = (try self.readFrame(arena)) orelse return ReadError.ClosedByPeer;

            if (fr.opcode.isControl()) {
                switch (fr.opcode) {
                    .close => {
                        if (!self.closed.swap(true, .seq_cst)) self.stream.close(self.io);
                        return ReadError.ClosedByPeer;
                    },
                    .ping => {
                        self.send(.pong, fr.payload) catch {};
                        continue :outer;
                    },
                    .pong => continue :outer,
                    else => return ReadError.InvalidFrame,
                }
            }

            if (first_opcode == null) first_opcode = fr.opcode;
            try assembled.appendSlice(self.gpa, fr.payload);
            if (assembled.items.len > self.max_payload) return ReadError.PayloadTooLarge;
            if (fr.fin) {
                const out = try arena.alloc(u8, assembled.items.len);
                @memcpy(out, assembled.items);
                return .{ .opcode = first_opcode.?, .payload = out };
            }
        }
    }

    fn readFrame(self: *Conn, arena: std.mem.Allocator) ReadError!?frame.Frame {
        while (true) {
            if (self.recv_buf.items.len > 0) {
                const r = frame.decode(arena, self.recv_buf.items, self.max_payload) catch |e| switch (e) {
                    frame.FrameError.Incomplete => null,
                    frame.FrameError.InvalidFrame => return ReadError.InvalidFrame,
                    frame.FrameError.UnsupportedReservedBits => return ReadError.UnsupportedReservedBits,
                    frame.FrameError.PayloadTooLarge => return ReadError.PayloadTooLarge,
                    frame.FrameError.OutOfMemory => return ReadError.OutOfMemory,
                };
                if (r) |dec| {
                    const remaining = self.recv_buf.items.len - dec.consumed;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, self.recv_buf.items[0..remaining], self.recv_buf.items[dec.consumed..]);
                    }
                    self.recv_buf.shrinkRetainingCapacity(remaining);
                    return dec.frame;
                }
            }
            var tmp: [4096]u8 = undefined;
            var sr_buf: [4096]u8 = undefined;
            var sr = self.stream.reader(self.io, &sr_buf);
            const reader: *Io.Reader = &sr.interface;
            const n = reader.readSliceShort(&tmp) catch return ReadError.ReadFailed;
            if (n == 0) return null;
            self.recv_buf.appendSlice(self.gpa, tmp[0..n]) catch return ReadError.OutOfMemory;
        }
    }
};

/// Perform a WebSocket upgrade. Accepts either the legacy `Ctx(App)` or the
/// new `Context(State)` — both expose the fields we need (`req`, `res`,
/// `arena`, `stream_ptr`, `io_ptr`) with the same shape.
pub fn upgrade(comptime CtxT: type, ctx: *CtxT, opts: UpgradeOptions) !Conn {
    // For the new Context(State), `ctx.req` is the Req wrapper struct; we need
    // header() to work on either. Both expose `.header(name)` so this just
    // works via duck typing.
    const upg = ctx.req.header("upgrade");
    const conn_h = ctx.req.header("connection");
    const ver = ctx.req.header("sec-websocket-version");
    const key = ctx.req.header("sec-websocket-key");

    if (!handshake.isUpgradeRequest(upg, conn_h, ver)) {
        ctx.res.setStatus(400);
        try ctx.res.text("invalid websocket upgrade");
        return error.NotUpgrade;
    }
    const client_key = key orelse {
        ctx.res.setStatus(400);
        try ctx.res.text("missing sec-websocket-key");
        return error.MissingKey;
    };

    var accept_buf: [64]u8 = undefined;
    const accept_len = try handshake.acceptKey(client_key, &accept_buf);
    const accept_value = try ctx.arena.dupe(u8, accept_buf[0..accept_len]);

    ctx.res.setStatus(101);
    ctx.res.is_upgrade = true;
    ctx.res.keep_alive = false;
    try ctx.res.header("upgrade", "websocket");
    try ctx.res.header("connection", "Upgrade");
    try ctx.res.header("sec-websocket-accept", accept_value);

    const stream_ptr: *net.Stream = @ptrCast(@alignCast(ctx.stream_ptr.?));
    const io_ptr: *Io = @ptrCast(@alignCast(ctx.io_ptr.?));

    // Send the 101 handshake response immediately so the caller can start
    // reading/writing WebSocket frames on the same socket. The HTTP server
    // sees `is_upgrade` and skips its own response write/flush, which would
    // otherwise race with the ws.Conn lifecycle and risk writing to an fd
    // already closed by Conn.deinit.
    var sw_buf: [1024]u8 = undefined;
    var sw = stream_ptr.writer(io_ptr.*, &sw_buf);
    const w: *std.Io.Writer = &sw.interface;
    try ctx.res.writeTo(w);
    try w.flush();
    ctx.res.finalized = true;

    return Conn.init(ctx.arena, stream_ptr.*, io_ptr.*, opts.max_message_bytes);
}
