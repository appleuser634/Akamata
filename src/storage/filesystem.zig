//! Native streaming object-store adapter rooted at a caller-owned directory.
//! Object bodies are never accumulated in application memory; a fixed 64 KiB
//! buffer provides backpressure between the portable Reader and the file.
const std = @import("std");
const storage = @import("../storage.zig");
const stream = @import("../stream.zig");

pub const FileStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) FileStore {
        return .{ .allocator = allocator, .io = io, .root = root };
    }

    pub fn store(self: *FileStore) storage.Store {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const ReaderState = struct {
        owner: *FileStore,
        file: std.Io.File,
        offset: u64,
        remaining: ?u64,
        metadata_buf: [4352]u8 = undefined,
        etag_len: usize = 0,
        content_type_start: usize = 0,
        content_type_len: usize = 0,
        custom_start: usize = 0,
        custom_len: usize = 0,

        fn read(ptr: *anyopaque, out: []u8) stream.Error!usize {
            const self: *ReaderState = @ptrCast(@alignCast(ptr));
            if (self.remaining == 0 or out.len == 0) return 0;
            const count: usize = if (self.remaining) |n| @intCast(@min(n, out.len)) else out.len;
            const n = self.file.readPositional(self.owner.io, &.{out[0..count]}, self.offset) catch return error.BackendFailure;
            self.offset += n;
            if (self.remaining) |remaining| self.remaining = remaining - n;
            return n;
        }

        fn close(ptr: *anyopaque) void {
            const self: *ReaderState = @ptrCast(@alignCast(ptr));
            self.file.close(self.owner.io);
            self.owner.allocator.destroy(self);
        }
    };

    fn put(raw: *anyopaque, key: []const u8, body: stream.Reader, options: storage.PutOptions) storage.Error!storage.Metadata {
        const self: *FileStore = @ptrCast(@alignCast(raw));
        try storage.validateKey(key);
        if (options.if_match != null) {
            var old = get(raw, key, .{}) catch |err| switch (err) {
                error.NotFound => return error.PreconditionFailed,
                else => return err,
            };
            defer old.body.close();
            if (storage.evaluate(old.metadata.etag, null, options.if_match) != .send) return error.PreconditionFailed;
        }
        if (std.fs.path.dirname(key)) |parent| self.root.createDirPath(self.io, parent) catch return error.BackendFailure;
        var file = self.root.createFile(self.io, key, .{ .resolve_beneath = true }) catch return error.BackendFailure;
        defer file.close(self.io);
        defer body.close();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var size: u64 = 0;
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const n = body.read(&buffer) catch return error.BackendFailure;
            if (n == 0) break;
            file.writeStreamingAll(self.io, buffer[0..n]) catch return error.BackendFailure;
            hasher.update(buffer[0..n]);
            size += n;
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const content_type = options.content_type orelse "application/octet-stream";
        if (content_type.len > 128 or std.mem.indexOfAny(u8, content_type, "\r\n\x00") != null) return error.PermissionDenied;
        const custom = options.metadata_json orelse "{}";
        if (custom.len > 4096) return error.PermissionDenied;
        const sidecar = std.fmt.allocPrint(self.allocator, ".akamata-meta/{s}", .{key}) catch return error.Unavailable;
        defer self.allocator.free(sidecar);
        if (std.fs.path.dirname(sidecar)) |parent| self.root.createDirPath(self.io, parent) catch return error.BackendFailure;
        var metadata_file = self.root.createFile(self.io, sidecar, .{ .resolve_beneath = true }) catch return error.BackendFailure;
        defer metadata_file.close(self.io);
        const hex = std.fmt.bytesToHex(digest, .lower);
        metadata_file.writeStreamingAll(self.io, "AM1\n\"") catch return error.BackendFailure;
        metadata_file.writeStreamingAll(self.io, &hex) catch return error.BackendFailure;
        metadata_file.writeStreamingAll(self.io, "\"\n") catch return error.BackendFailure;
        metadata_file.writeStreamingAll(self.io, content_type) catch return error.BackendFailure;
        metadata_file.writeStreamingAll(self.io, "\n") catch return error.BackendFailure;
        metadata_file.writeStreamingAll(self.io, custom) catch return error.BackendFailure;
        return .{ .size = size, .etag = null };
    }

    fn get(raw: *anyopaque, key: []const u8, options: storage.GetOptions) storage.Error!storage.Object {
        const self: *FileStore = @ptrCast(@alignCast(raw));
        try storage.validateKey(key);
        const metadata = try head(raw, key);
        var offset: u64 = 0;
        var remaining: ?u64 = null;
        if (options.range) |range| {
            if (range.offset >= metadata.size) return error.InvalidRange;
            offset = range.offset;
            remaining = @min(range.length orelse metadata.size - offset, metadata.size - offset);
        }
        const file = self.root.openFile(self.io, key, .{ .resolve_beneath = true }) catch |err| return mapOpen(err);
        const state = self.allocator.create(ReaderState) catch {
            file.close(self.io);
            return error.Unavailable;
        };
        state.* = .{ .owner = self, .file = file, .offset = offset, .remaining = remaining };
        loadMetadata(self, key, state);
        var result = metadata;
        if (remaining) |n| result.size = n;
        result.etag = if (state.etag_len == 0) null else state.metadata_buf[0..state.etag_len];
        result.content_type = if (state.content_type_len == 0) null else state.metadata_buf[state.content_type_start..][0..state.content_type_len];
        result.custom_json = if (state.custom_len == 0) null else state.metadata_buf[state.custom_start..][0..state.custom_len];
        if (storage.evaluate(result.etag, options.if_none_match, options.if_match) != .send) {
            ReaderState.close(state);
            return error.PreconditionFailed;
        }
        return .{ .metadata = result, .body = .{ .ptr = state, .read_fn = ReaderState.read, .close_fn = ReaderState.close } };
    }

    fn delete(raw: *anyopaque, key: []const u8) storage.Error!void {
        const self: *FileStore = @ptrCast(@alignCast(raw));
        try storage.validateKey(key);
        self.root.deleteFile(self.io, key) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            error.AccessDenied => return error.PermissionDenied,
            else => return error.BackendFailure,
        };
        const sidecar = std.fmt.allocPrint(self.allocator, ".akamata-meta/{s}", .{key}) catch return;
        defer self.allocator.free(sidecar);
        self.root.deleteFile(self.io, sidecar) catch {};
    }

    fn head(raw: *anyopaque, key: []const u8) storage.Error!storage.Metadata {
        const self: *FileStore = @ptrCast(@alignCast(raw));
        try storage.validateKey(key);
        const stat = self.root.statFile(self.io, key, .{}) catch |err| return mapOpen(err);
        if (stat.kind != .file) return error.NotFound;
        return .{ .size = stat.size, .modified_at_ms = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)) };
    }

    fn list(raw: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8, cursor: ?[]const u8, limit: usize) storage.Error![]storage.ListEntry {
        const self: *FileStore = @ptrCast(@alignCast(raw));
        if (prefix.len != 0) {
            if (prefix[0] == '/' or std.mem.indexOf(u8, prefix, "..") != null or std.mem.indexOfScalar(u8, prefix, '\\') != null) return error.PermissionDenied;
        }
        var walker = self.root.walk(allocator) catch return error.Unavailable;
        defer walker.deinit();
        var entries: std.ArrayList(storage.ListEntry) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.key);
            entries.deinit(allocator);
        }
        while (walker.next(self.io) catch return error.BackendFailure) |entry| {
            if (entry.kind != .file or std.mem.startsWith(u8, entry.path, ".akamata-meta/") or !std.mem.startsWith(u8, entry.path, prefix)) continue;
            if (cursor) |after| if (std.mem.order(u8, entry.path, after) != .gt) continue;
            const stat = entry.dir.statFile(self.io, entry.basename, .{}) catch continue;
            entries.append(allocator, .{
                .key = allocator.dupe(u8, entry.path) catch return error.Unavailable,
                .metadata = .{ .size = stat.size, .modified_at_ms = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)) },
            }) catch return error.Unavailable;
        }
        std.mem.sort(storage.ListEntry, entries.items, {}, struct {
            fn less(_: void, a: storage.ListEntry, b: storage.ListEntry) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.less);
        if (entries.items.len > limit) {
            for (entries.items[limit..]) |entry| allocator.free(entry.key);
            entries.shrinkRetainingCapacity(limit);
        }
        return entries.toOwnedSlice(allocator) catch return error.Unavailable;
    }

    fn mapOpen(err: anyerror) storage.Error {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied, error.PermissionDenied => error.PermissionDenied,
            else => error.BackendFailure,
        };
    }

    fn loadMetadata(self: *FileStore, key: []const u8, state: *ReaderState) void {
        const sidecar = std.fmt.allocPrint(self.allocator, ".akamata-meta/{s}", .{key}) catch return;
        defer self.allocator.free(sidecar);
        const file = self.root.openFile(self.io, sidecar, .{ .resolve_beneath = true }) catch return;
        defer file.close(self.io);
        const n = file.readPositional(self.io, &.{&state.metadata_buf}, 0) catch return;
        const bytes = state.metadata_buf[0..n];
        if (!std.mem.startsWith(u8, bytes, "AM1\n")) return;
        const etag_end = std.mem.indexOfScalarPos(u8, bytes, 4, '\n') orelse return;
        const type_end = std.mem.indexOfScalarPos(u8, bytes, etag_end + 1, '\n') orelse return;
        const etag = bytes[4..etag_end];
        if (etag.len > 128) return;
        std.mem.copyForwards(u8, state.metadata_buf[0..etag.len], etag);
        state.etag_len = etag.len;
        state.content_type_start = etag.len;
        state.content_type_len = type_end - etag_end - 1;
        std.mem.copyForwards(u8, state.metadata_buf[state.content_type_start..][0..state.content_type_len], bytes[etag_end + 1 .. type_end]);
        state.custom_start = state.content_type_start + state.content_type_len;
        state.custom_len = n - type_end - 1;
        std.mem.copyForwards(u8, state.metadata_buf[state.custom_start..][0..state.custom_len], bytes[type_end + 1 .. n]);
    }

    const vtable: storage.Store.VTable = .{ .put = put, .get = get, .delete = delete, .head = head, .list = list };
};

test "filesystem adapter streams body and byte range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs = FileStore.init(std.testing.allocator, std.testing.io, tmp.dir);

    const Source = struct {
        bytes: []const u8,
        offset: usize = 0,
        fn read(ptr: *anyopaque, out: []u8) stream.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const n = @min(out.len, self.bytes.len - self.offset);
            @memcpy(out[0..n], self.bytes[self.offset..][0..n]);
            self.offset += n;
            return n;
        }
        fn close(_: *anyopaque) void {}
    };
    var source = Source{ .bytes = "0123456789" };
    const s = fs.store();
    const meta = try s.put("objects/test.bin", .{ .ptr = &source, .read_fn = Source.read, .close_fn = Source.close }, .{ .content_type = "application/octet-stream" });
    try std.testing.expectEqual(@as(u64, 10), meta.size);
    var object = try s.get("objects/test.bin", .{ .range = .{ .offset = 3, .length = 4 } });
    defer object.body.close();
    try std.testing.expect(object.metadata.etag != null);
    try std.testing.expectEqualStrings("application/octet-stream", object.metadata.content_type.?);
    var out: [8]u8 = undefined;
    const n = try object.body.read(&out);
    try std.testing.expectEqualStrings("3456", out[0..n]);
    const listed = try s.list(std.testing.allocator, "objects/", null, 10);
    defer {
        for (listed) |entry| std.testing.allocator.free(entry.key);
        std.testing.allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("objects/test.bin", listed[0].key);
    try std.testing.expectError(error.PreconditionFailed, s.get("objects/test.bin", .{ .if_none_match = object.metadata.etag }));
}
