//! Portable outbound byte-stream connections. Concrete native std.net and
//! Workers Socket adapters implement this small interface.
const stream = @import("stream.zig");

pub const Tls = enum { disabled, opportunistic, required };
pub const ConnectOptions = struct {
    host: []const u8,
    port: u16,
    timeout_ms: u32 = 10_000,
    tls: Tls = .disabled,
};
pub const Error = error{ DnsFailure, ConnectionRefused, Timeout, Closed, TlsFailure, Unsupported, BackendFailure };
pub const Connection = struct {
    reader: stream.Reader,
    writer: stream.Writer,
    close_fn: *const fn (*anyopaque) void,
    ptr: *anyopaque,
    pub fn close(self: Connection) void {
        self.close_fn(self.ptr);
    }
};
pub const Connector = struct {
    ptr: *anyopaque,
    connect_fn: *const fn (*anyopaque, ConnectOptions) Error!Connection,
    pub fn connect(self: Connector, options: ConnectOptions) Error!Connection {
        return self.connect_fn(self.ptr, options);
    }
};
