//! Portable object storage contract. Native filesystem and Workers R2 adapt
//! to this VTable; metadata and range semantics stay application-facing.
const std = @import("std");
const stream = @import("stream.zig");

pub const Error = error{ NotFound, InvalidRange, PreconditionFailed, PermissionDenied, Unavailable, BackendFailure };
pub const Range = struct { offset: u64, length: ?u64 = null };
pub const Metadata = struct {
    size: u64,
    etag: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    modified_at_ms: ?i64 = null,
    custom_json: ?[]const u8 = null,
};
pub const PutOptions = struct { content_type: ?[]const u8 = null, metadata_json: ?[]const u8 = null, if_match: ?[]const u8 = null };
pub const GetOptions = struct { range: ?Range = null, if_match: ?[]const u8 = null, if_none_match: ?[]const u8 = null };
pub const Object = struct { metadata: Metadata, body: stream.Reader };
pub const ListEntry = struct { key: []const u8, metadata: Metadata };

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        put: *const fn (*anyopaque, []const u8, stream.Reader, PutOptions) Error!Metadata,
        get: *const fn (*anyopaque, []const u8, GetOptions) Error!Object,
        delete: *const fn (*anyopaque, []const u8) Error!void,
        head: *const fn (*anyopaque, []const u8) Error!Metadata,
        list: *const fn (*anyopaque, std.mem.Allocator, []const u8, ?[]const u8, usize) Error![]ListEntry,
    };
    pub fn put(self: Store, key: []const u8, body: stream.Reader, options: PutOptions) Error!Metadata {
        return self.vtable.put(self.ptr, key, body, options);
    }
    pub fn get(self: Store, key: []const u8, options: GetOptions) Error!Object {
        return self.vtable.get(self.ptr, key, options);
    }
    pub fn delete(self: Store, key: []const u8) Error!void {
        return self.vtable.delete(self.ptr, key);
    }
    pub fn head(self: Store, key: []const u8) Error!Metadata {
        return self.vtable.head(self.ptr, key);
    }
    pub fn list(self: Store, allocator: std.mem.Allocator, prefix: []const u8, cursor: ?[]const u8, limit: usize) Error![]ListEntry {
        return self.vtable.list(self.ptr, allocator, prefix, cursor, limit);
    }
};

pub const Conditional = enum { send, not_modified, precondition_failed };
pub fn evaluate(etag: ?[]const u8, if_none_match: ?[]const u8, if_match: ?[]const u8) Conditional {
    if (if_match) |expected| if (etag == null or !std.mem.eql(u8, etag.?, expected)) return .precondition_failed;
    if (if_none_match) |expected| if (etag != null and std.mem.eql(u8, etag.?, expected)) return .not_modified;
    return .send;
}

pub fn parseRange(value: []const u8, size: u64) !Range {
    if (!std.mem.startsWith(u8, value, "bytes=")) return error.InvalidRange;
    const raw = value[6..];
    const dash = std.mem.indexOfScalar(u8, raw, '-') orelse return error.InvalidRange;
    if (dash == 0) {
        const suffix = try std.fmt.parseInt(u64, raw[1..], 10);
        if (suffix == 0) return error.InvalidRange;
        const length = @min(suffix, size);
        return .{ .offset = size - length, .length = length };
    }
    const start = try std.fmt.parseInt(u64, raw[0..dash], 10);
    if (start >= size) return error.InvalidRange;
    if (dash + 1 == raw.len) return .{ .offset = start, .length = size - start };
    const end = try std.fmt.parseInt(u64, raw[dash + 1 ..], 10);
    if (end < start) return error.InvalidRange;
    return .{ .offset = start, .length = @min(end, size - 1) - start + 1 };
}

test "HTTP range and conditionals" {
    try std.testing.expectEqual(Range{ .offset = 10, .length = 10 }, try parseRange("bytes=10-19", 100));
    try std.testing.expectEqual(Range{ .offset = 90, .length = 10 }, try parseRange("bytes=-10", 100));
    try std.testing.expectEqual(Conditional.not_modified, evaluate("v1", "v1", null));
}
