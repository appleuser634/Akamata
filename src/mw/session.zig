// Signed-cookie session middleware with a pluggable store.
//
// The cookie carries an opaque session ID; the actual key/value bag lives in
// the `Store`. We sign the ID with HMAC-SHA256(secret) and reject any cookie
// with a bad MAC so the client can't forge a session by guessing IDs.

const std = @import("std");
const app_mod = @import("../app.zig");
const cookie_mod = @import("../http/cookie.zig");
const sync = @import("../sync.zig");
const clock = @import("../observability/clock.zig");
const random = @import("../crypto/random.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64url = std.base64.url_safe_no_pad;

pub const Options = struct {
    /// HMAC-SHA256 secret for the cookie signature. Must be stable across
    /// restarts or every existing session is invalidated.
    secret: []const u8,
    cookie_name: []const u8 = "AKID",
    cookie_path: []const u8 = "/",
    cookie_max_age_secs: i64 = 60 * 60 * 24 * 7, // 1 week
    cookie_secure: bool = true,
    cookie_http_only: bool = true,
    cookie_same_site: cookie_mod.SameSite = .lax,
    /// If non-null, this Store is used for value persistence. A null store
    /// means "in-memory, per-process" (created lazily on first request via
    /// `MemoryStore`).
    store: ?*Store = null,
    /// Refresh the signed server-enforced expiry on each valid request.
    sliding_expiration: bool = false,
    now_fn: *const fn () i64 = clock.unixSeconds,
};

// ----- Store interface -----

pub const Store = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, sid: []const u8, key: []const u8, out: *std.ArrayList(u8), out_alloc: std.mem.Allocator) anyerror!bool,
        set: *const fn (ptr: *anyopaque, sid: []const u8, key: []const u8, value: []const u8) anyerror!void,
        delete: *const fn (ptr: *anyopaque, sid: []const u8, key: []const u8) anyerror!void,
        destroy: *const fn (ptr: *anyopaque, sid: []const u8) anyerror!void,
    };

    pub fn get(self: Store, sid: []const u8, key: []const u8, out: *std.ArrayList(u8), out_alloc: std.mem.Allocator) !bool {
        return self.vt.get(self.ptr, sid, key, out, out_alloc);
    }
    pub fn set(self: Store, sid: []const u8, key: []const u8, value: []const u8) !void {
        return self.vt.set(self.ptr, sid, key, value);
    }
    pub fn delete(self: Store, sid: []const u8, key: []const u8) !void {
        return self.vt.delete(self.ptr, sid, key);
    }
    pub fn destroy(self: Store, sid: []const u8) !void {
        return self.vt.destroy(self.ptr, sid);
    }
};

// ----- Built-in in-memory store -----

pub const MemoryStore = struct {
    gpa: std.mem.Allocator,
    mu: sync.Mutex = .{},
    /// sid -> (key -> value), all owned by `gpa`.
    sessions: std.StringHashMap(*std.StringHashMap([]u8)),

    pub fn init(gpa: std.mem.Allocator) MemoryStore {
        return .{
            .gpa = gpa,
            .sessions = .init(gpa),
            .mu = sync.Mutex.init(),
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            var inner_it = entry.value_ptr.*.iterator();
            while (inner_it.next()) |kv| {
                self.gpa.free(kv.key_ptr.*);
                self.gpa.free(kv.value_ptr.*);
            }
            entry.value_ptr.*.deinit();
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
        self.mu.deinit();
    }

    pub fn store(self: *MemoryStore) Store {
        return .{ .ptr = self, .vt = &memory_vtable };
    }

    fn ensureMap(self: *MemoryStore, sid: []const u8) !*std.StringHashMap([]u8) {
        if (self.sessions.getPtr(sid)) |p| return p.*;
        const key = try self.gpa.dupe(u8, sid);
        const m = try self.gpa.create(std.StringHashMap([]u8));
        m.* = .init(self.gpa);
        try self.sessions.put(key, m);
        return m;
    }
};

fn memoryGet(ptr: *anyopaque, sid: []const u8, key: []const u8, out: *std.ArrayList(u8), out_alloc: std.mem.Allocator) anyerror!bool {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    self.mu.lock();
    defer self.mu.unlock();
    const m = self.sessions.get(sid) orelse return false;
    const v = m.get(key) orelse return false;
    try out.appendSlice(out_alloc, v);
    return true;
}

fn memorySet(ptr: *anyopaque, sid: []const u8, key: []const u8, value: []const u8) anyerror!void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    self.mu.lock();
    defer self.mu.unlock();
    const m = try self.ensureMap(sid);
    if (m.fetchRemove(key)) |old| {
        self.gpa.free(old.key);
        self.gpa.free(old.value);
    }
    const k = try self.gpa.dupe(u8, key);
    const v = try self.gpa.dupe(u8, value);
    try m.put(k, v);
}

fn memoryDelete(ptr: *anyopaque, sid: []const u8, key: []const u8) anyerror!void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    self.mu.lock();
    defer self.mu.unlock();
    const m = self.sessions.get(sid) orelse return;
    if (m.fetchRemove(key)) |old| {
        self.gpa.free(old.key);
        self.gpa.free(old.value);
    }
}

fn memoryDestroy(ptr: *anyopaque, sid: []const u8) anyerror!void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    self.mu.lock();
    defer self.mu.unlock();
    if (self.sessions.fetchRemove(sid)) |entry| {
        self.gpa.free(entry.key);
        var it = entry.value.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.gpa.free(kv.value_ptr.*);
        }
        entry.value.deinit();
        self.gpa.destroy(entry.value);
    }
}

const memory_vtable: Store.VTable = .{
    .get = memoryGet,
    .set = memorySet,
    .delete = memoryDelete,
    .destroy = memoryDestroy,
};

// ----- Session handle (the thing handlers actually use) -----

pub const Session = struct {
    sid: []const u8,
    store: Store,
    arena: std.mem.Allocator,
    secret: []const u8,
    cookie_name: []const u8,
    cookie_path: []const u8,
    cookie_max_age_secs: i64,
    cookie_secure: bool,
    cookie_http_only: bool,
    cookie_same_site: cookie_mod.SameSite,
    now_fn: *const fn () i64,

    /// Return value if present. Allocates in the request arena.
    pub fn get(self: Session, key: []const u8) !?[]u8 {
        var buf: std.ArrayList(u8) = .empty;
        const found = try self.store.get(self.sid, key, &buf, self.arena);
        if (!found) return null;
        return try buf.toOwnedSlice(self.arena);
    }

    pub fn set(self: Session, key: []const u8, value: []const u8) !void {
        try self.store.set(self.sid, key, value);
    }

    pub fn delete(self: Session, key: []const u8) !void {
        try self.store.delete(self.sid, key);
    }

    pub fn destroy(self: Session) !void {
        try self.store.destroy(self.sid);
    }

    /// Rotate the SID after login or privilege changes. Existing data is
    /// deliberately destroyed to prevent fixation across trust boundaries.
    pub fn rotate(self: *Session, c: anytype) !void {
        try self.store.destroy(self.sid);
        self.sid = try mintSessionId(self.arena);
        const expires_at = try std.math.add(i64, self.now_fn(), self.cookie_max_age_secs);
        const signed = try sign(self.arena, self.secret, self.sid, expires_at);
        try c.setCookie(self.cookie_name, signed, .{
            .path = self.cookie_path,
            .max_age_secs = self.cookie_max_age_secs,
            .secure = self.cookie_secure,
            .http_only = self.cookie_http_only,
            .same_site = self.cookie_same_site,
        });
    }
};

// ----- Middleware factory -----

/// Wire a session middleware into the App. Stash a `*Session` into
/// `c.user_data` for handlers to grab via `currentSession(c)`.
///
/// On first request without a cookie, a new random session ID is minted
/// and a signed cookie is emitted on the response.
pub fn session(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        const Runtime = struct {
            store: Store,
            owned_memory_store: ?*MemoryStore,
        };

        fn setup(gpa: std.mem.Allocator) !*anyopaque {
            const runtime = try gpa.create(Runtime);
            errdefer gpa.destroy(runtime);
            if (opts.store) |s| {
                runtime.* = .{ .store = s.*, .owned_memory_store = null };
                return runtime;
            }
            const ms = try gpa.create(MemoryStore);
            ms.* = MemoryStore.init(gpa);
            runtime.* = .{ .store = ms.store(), .owned_memory_store = ms };
            return runtime;
        }

        fn cleanup(gpa: std.mem.Allocator, data: *anyopaque) void {
            const runtime: *Runtime = @ptrCast(@alignCast(data));
            if (runtime.owned_memory_store) |ms| {
                ms.deinit();
                gpa.destroy(ms);
            }
            gpa.destroy(runtime);
        }

        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            if (opts.secret.len < 32) return error.SessionSecretTooShort;
            if (opts.cookie_max_age_secs <= 0) return error.InvalidSessionLifetime;
            const runtime: *Runtime = @ptrCast(@alignCast(c.middleware_data orelse return error.MiddlewareNotInitialized));
            const st = runtime.store;
            const sid_opt = readSid(c, st);
            const sid = if (sid_opt) |s| s else try mintSid(c);
            const sess = try c.arena.create(Session);
            sess.* = .{
                .sid = sid,
                .store = st,
                .arena = c.arena,
                .secret = opts.secret,
                .cookie_name = opts.cookie_name,
                .cookie_path = opts.cookie_path,
                .cookie_max_age_secs = opts.cookie_max_age_secs,
                .cookie_secure = opts.cookie_secure,
                .cookie_http_only = opts.cookie_http_only,
                .cookie_same_site = opts.cookie_same_site,
                .now_fn = opts.now_fn,
            };
            c.session_data = @ptrCast(sess);

            if (sid_opt == null or opts.sliding_expiration) {
                const expires_at = std.math.add(i64, opts.now_fn(), opts.cookie_max_age_secs) catch return error.InvalidSessionLifetime;
                const signed = try sign(c.arena, opts.secret, sid, expires_at);
                try c.setCookie(opts.cookie_name, signed, .{
                    .path = opts.cookie_path,
                    .max_age_secs = opts.cookie_max_age_secs,
                    .secure = opts.cookie_secure,
                    .http_only = opts.cookie_http_only,
                    .same_site = opts.cookie_same_site,
                });
            }
            return next.run(c);
        }

        fn readSid(c: *app_mod.App(State).Ctx, st: Store) ?[]const u8 {
            const raw = c.req.cookie(opts.cookie_name) orelse return null;
            const verified = verify(c.arena, opts.secret, raw, opts.now_fn()) catch |err| {
                if (err == error.ExpiredCookie) {
                    if (untrustedSid(raw)) |sid| st.destroy(sid) catch {};
                }
                return null;
            };
            return verified.sid;
        }

        fn mintSid(c: *app_mod.App(State).Ctx) ![]u8 {
            return mintSessionId(c.arena);
        }
    };
    return .{ .name = "session", .call = Impl.call, .setup = Impl.setup, .cleanup = Impl.cleanup };
}

fn mintSessionId(arena: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    random.fill(&raw);
    const enc_len = b64url.Encoder.calcSize(raw.len);
    const out = try arena.alloc(u8, enc_len);
    _ = b64url.Encoder.encode(out, &raw);
    return out;
}

pub fn currentSession(comptime State: type, c: *app_mod.App(State).Ctx) ?*Session {
    const p = c.session_data orelse return null;
    return @ptrCast(@alignCast(p));
}

// ----- Cookie signing -----

const VerifiedCookie = struct { sid: []const u8, expires_at: i64 };

fn sign(arena: std.mem.Allocator, secret: []const u8, sid: []const u8, expires_at: i64) ![]u8 {
    const payload = try std.fmt.allocPrint(arena, "{s}.{d}", .{ sid, expires_at });
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, payload, secret);
    const enc_len = b64url.Encoder.calcSize(mac.len);
    var out = try arena.alloc(u8, payload.len + 1 + enc_len);
    @memcpy(out[0..payload.len], payload);
    out[payload.len] = '.';
    _ = b64url.Encoder.encode(out[payload.len + 1 ..], &mac);
    return out;
}

fn verify(arena: std.mem.Allocator, secret: []const u8, signed: []const u8, now: i64) !VerifiedCookie {
    const dot1 = std.mem.indexOfScalar(u8, signed, '.') orelse return error.BadCookie;
    const dot2 = std.mem.indexOfScalarPos(u8, signed, dot1 + 1, '.') orelse return error.BadCookie;
    if (std.mem.indexOfScalarPos(u8, signed, dot2 + 1, '.') != null) return error.BadCookie;
    const sid_part = signed[0..dot1];
    if (sid_part.len == 0 or sid_part.len > 128) return error.BadCookie;
    const expires_at = std.fmt.parseInt(i64, signed[dot1 + 1 .. dot2], 10) catch return error.BadCookie;
    const mac_b64 = signed[dot2 + 1 ..];

    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, signed[0..dot2], secret);

    var got: [HmacSha256.mac_length]u8 = undefined;
    if (mac_b64.len != b64url.Encoder.calcSize(got.len)) return error.BadCookie;
    b64url.Decoder.decode(&got, mac_b64) catch return error.BadCookie;
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, got, expected)) {
        return error.BadCookie;
    }
    if (now >= expires_at) return error.ExpiredCookie;
    return .{ .sid = try arena.dupe(u8, sid_part), .expires_at = expires_at };
}

fn untrustedSid(signed: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, signed, '.') orelse return null;
    const sid = signed[0..dot];
    if (sid.len == 0 or sid.len > 128) return null;
    return sid;
}

test "sign/verify roundtrip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const signed = try sign(arena, "s3cr3t", "abc123", 200);
    const back = try verify(arena, "s3cr3t", signed, 100);
    try std.testing.expectEqualStrings("abc123", back.sid);
    try std.testing.expectError(error.ExpiredCookie, verify(arena, "s3cr3t", signed, 200));
}

test "verify rejects tampered signature" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signed = try sign(arena, "s3cr3t", "abc123", 200);
    signed[signed.len - 1] ^= 0x01;
    try std.testing.expectError(error.BadCookie, verify(arena, "s3cr3t", signed, 100));
}

test "signed expiry cannot be forged" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signed = try sign(arena, "s3cr3t", "abc123", 200);
    signed[7] = '9';
    try std.testing.expectError(error.BadCookie, verify(arena, "s3cr3t", signed, 100));
}

test "MemoryStore get/set/delete" {
    const alloc = std.testing.allocator;
    var ms = MemoryStore.init(alloc);
    defer ms.deinit();
    const st = ms.store();
    try st.set("sid1", "name", "alice");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const found = try st.get("sid1", "name", &buf, alloc);
    try std.testing.expect(found);
    try std.testing.expectEqualStrings("alice", buf.items);
    try st.delete("sid1", "name");
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(alloc);
    const found2 = try st.get("sid1", "name", &buf2, alloc);
    try std.testing.expect(!found2);
}
