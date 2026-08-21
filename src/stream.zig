//! Bounded, pull-based byte streams. Backpressure is explicit: the consumer
//! asks for the next chunk and must finish it before requesting another.
pub const Error = error{ Closed, Timeout, BackendFailure };

pub const Reader = struct {
    ptr: *anyopaque,
    read_fn: *const fn (*anyopaque, []u8) Error!usize,
    close_fn: *const fn (*anyopaque) void,

    pub fn read(self: Reader, buffer: []u8) Error!usize {
        return self.read_fn(self.ptr, buffer);
    }
    pub fn close(self: Reader) void {
        self.close_fn(self.ptr);
    }
};

pub const Writer = struct {
    ptr: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) Error!usize,
    close_fn: *const fn (*anyopaque) Error!void,

    pub fn write(self: Writer, bytes: []const u8) Error!usize {
        return self.write_fn(self.ptr, bytes);
    }
    pub fn close(self: Writer) Error!void {
        return self.close_fn(self.ptr);
    }
};

pub fn copy(reader: Reader, writer: Writer, buffer: []u8) !u64 {
    var total: u64 = 0;
    while (true) {
        const n = try reader.read(buffer);
        if (n == 0) break;
        var offset: usize = 0;
        while (offset < n) offset += try writer.write(buffer[offset..n]);
        total += n;
    }
    return total;
}
