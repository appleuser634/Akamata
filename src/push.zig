const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const http_client = @import("http_client.zig");
const rs256 = @import("crypto/rs256.zig");

const is_native = build_options.backend == .native;

pub const PushError = error{
    NoServiceAccount,
    TokenFetchFailed,
    SendFailed,
    JsonFailure,
    OutOfMemory,
    UnsupportedOnTarget,
};

extern "c" fn time(t: ?*i64) i64;
fn timeNow() i64 {
    if (!is_native) return 0;
    return time(null);
}

pub const ServiceAccount = struct {
    project_id: []const u8,
    client_email: []const u8,
    private_key: []const u8, // PEM
};

pub const Notification = struct {
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    data: ?std.json.Value = null, // optional key-value payload
};

/// FCM sender. Holds cached access token between calls.
pub const Sender = struct {
    gpa: std.mem.Allocator,
    service_account: ?ServiceAccount = null,
    access_token: ?[]u8 = null,
    expiry_unix: i64 = 0,

    pub fn init(gpa: std.mem.Allocator) Sender {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Sender) void {
        if (self.access_token) |t| self.gpa.free(t);
        if (self.service_account) |sa| {
            self.gpa.free(sa.project_id);
            self.gpa.free(sa.client_email);
            self.gpa.free(sa.private_key);
        }
    }

    /// Load a Google service account JSON from disk via libc. Native only.
    pub fn loadServiceAccountFromFile(self: *Sender, path: []const u8) !void {
        if (!is_native) return PushError.UnsupportedOnTarget;
        const path_z = try self.gpa.dupeZ(u8, path);
        defer self.gpa.free(path_z);

        const FILE = opaque {};
        const Lib = struct {
            extern "c" fn fopen(p: [*:0]const u8, m: [*:0]const u8) ?*FILE;
            extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, s: *FILE) usize;
            extern "c" fn fclose(s: *FILE) c_int;
        };
        const f = Lib.fopen(path_z.ptr, "rb") orelse return PushError.NoServiceAccount;
        defer _ = Lib.fclose(f);

        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(self.gpa);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = Lib.fread(&buf, 1, buf.len, f);
            if (n == 0) break;
            try content.appendSlice(self.gpa, buf[0..n]);
        }
        try self.loadServiceAccountFromJson(content.items);
    }

    pub fn loadServiceAccountFromJson(self: *Sender, json_bytes: []const u8) !void {
        const Shape = struct {
            project_id: []const u8,
            client_email: []const u8,
            private_key: []const u8,
        };
        var parsed = std.json.parseFromSlice(Shape, self.gpa, json_bytes, .{
            .ignore_unknown_fields = true,
        }) catch return PushError.JsonFailure;
        defer parsed.deinit();

        self.service_account = .{
            .project_id = try self.gpa.dupe(u8, parsed.value.project_id),
            .client_email = try self.gpa.dupe(u8, parsed.value.client_email),
            .private_key = try self.gpa.dupe(u8, parsed.value.private_key),
        };
    }

    /// Send a notification to a single device token.
    pub fn send(self: *Sender, device_token: []const u8, note: Notification) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const token = try self.ensureAccessToken(arena);
        const sa = self.service_account orelse return PushError.NoServiceAccount;

        const url = try std.fmt.allocPrint(arena, "https://fcm.googleapis.com/v1/projects/{s}/messages:send", .{sa.project_id});

        // Build the JSON body.
        var body_buf: std.ArrayList(u8) = .empty;
        var aw: std.Io.Writer.Allocating = .fromArrayList(arena, &body_buf);
        defer body_buf = aw.toArrayList();

        const Msg = struct {
            message: struct {
                token: []const u8,
                notification: struct {
                    title: ?[]const u8,
                    body: ?[]const u8,
                },
            },
        };
        try std.json.Stringify.value(Msg{
            .message = .{
                .token = device_token,
                .notification = .{ .title = note.title, .body = note.body },
            },
        }, .{ .emit_null_optional_fields = false }, &aw.writer);

        const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
        const headers = [_]http_client.Header{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
        };
        const resp = http_client.send(arena, .{
            .method = .POST,
            .url = url,
            .headers = &headers,
            .body = aw.writer.buffered(),
        }) catch return PushError.SendFailed;
        if (resp.status < 200 or resp.status >= 300) return PushError.SendFailed;
    }

    fn ensureAccessToken(self: *Sender, arena: std.mem.Allocator) ![]const u8 {
        const now = timeNow();
        if (self.access_token != null and now + 60 < self.expiry_unix) {
            return self.access_token.?;
        }
        const sa = self.service_account orelse return PushError.NoServiceAccount;

        // RS256 JWT
        const jwt = try rs256.buildGoogleJwt(
            arena,
            sa.private_key,
            sa.client_email,
            "https://www.googleapis.com/auth/firebase.messaging",
            "https://oauth2.googleapis.com/token",
            now,
            3600,
        );

        // POST grant_type=...&assertion=jwt
        const form = try std.fmt.allocPrint(
            arena,
            "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}",
            .{jwt},
        );
        const headers = [_]http_client.Header{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        };
        const resp = http_client.send(arena, .{
            .method = .POST,
            .url = "https://oauth2.googleapis.com/token",
            .headers = &headers,
            .body = form,
        }) catch return PushError.TokenFetchFailed;
        if (resp.status < 200 or resp.status >= 300) return PushError.TokenFetchFailed;

        const Body = struct { access_token: []const u8, expires_in: i64 };
        const parsed = std.json.parseFromSliceLeaky(Body, arena, resp.body, .{
            .ignore_unknown_fields = true,
        }) catch return PushError.JsonFailure;

        // Cache (caller owns lifetime of these copies)
        if (self.access_token) |old| self.gpa.free(old);
        self.access_token = try self.gpa.dupe(u8, parsed.access_token);
        self.expiry_unix = now + parsed.expires_in;
        return self.access_token.?;
    }
};
