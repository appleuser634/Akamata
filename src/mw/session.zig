// Signed-cookie session middleware with a pluggable store.
//
// The cookie carries an opaque session ID; the actual key/value bag lives in
// the `Store`. We sign the ID with HMAC-SHA256(secret) and reject any cookie
// with a bad MAC so the client can't forge a session by guessing IDs.

const std = @import("std");
const app_mod = @import("../app.zig");
const cookie_mod = @import("../http/cookie.zig");
const sync = @import("../sync.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const b64url = std.base64.url_safe_no_pad;

pub const Options = struct {
    /// HMAC-SHA256 secret for the cookie signature. Must be stable across
    /// restarts or every existing session is invalidated.
    secret: []const u8,
    cookie_name: []const u8 = "AKID",
    cookie_path: []const u8 = "/",
    cookie_max_age_secs: i64 = 60 * 60 * 24 * 7, // 1 week
    cookie_secure: bool = false,
    cookie_http_only: bool = true,
    cookie_same_site: cookie_mod.SameSite = .lax,
    /// If non-null, this Store is used for value persistence. A null store
    /// means "in-memory, per-process" (created lazily on first request via
    /// `MemoryStore`).
    store: ?*Store = null,
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

    /// Return value if present. Allocates in the request arena.
    pub fn get(self: Session, key: []const u8) !?[]u8 {
        var buf: std.ArrayList(u8) = .empty;
        const found = try self.store.get(self.sid, key, &buf, self.arena);
        if (!found) return null;
        return buf.toOwnedSlice(self.arena);
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
};

// ----- Middleware factory -----

/// Wire a session middleware into the App. Stash a `*Session` into
/// `c.user_data` for handlers to grab via `currentSession(c)`.
///
/// On first request without a cookie, a new random session ID is minted
/// and a signed cookie is emitted on the response.
pub fn session(comptime State: type, comptime opts: Options) app_mod.Middleware(State) {
    const Impl = struct {
        var store_slot: ?Store = null;
        var inited: std.atomic.Value(u8) = .init(0);

        fn ensureStore(c: *app_mod.App(State).Ctx) !Store {
            // Fast path: already initialised
            if (inited.load(.acquire) == 2) return store_slot.?;
            if (opts.store) |s| {
                if (inited.cmpxchgStrong(0, 1, .acq_rel, .monotonic) == null) {
                    store_slot = s.*;
                    inited.store(2, .release);
                }
                return store_slot.?;
            }
            // Build an in-memory store on first hit. We leak the MemoryStore
            // for the process lifetime — sessions are gone on restart anyway.
            if (inited.cmpxchgStrong(0, 1, .acq_rel, .monotonic) == null) {
                const ms = std.heap.smp_allocator.create(MemoryStore) catch |e| {
                    // Allow another thread to retry by resetting the CAS slot.
                    inited.store(0, .release);
                    return e;
                };
                ms.* = MemoryStore.init(std.heap.smp_allocator);
                store_slot = ms.store();
                inited.store(2, .release);
            } else {
                while (inited.load(.acquire) != 2) std.atomic.spinLoopHint();
            }
            _ = c;
            return store_slot.?;
        }

        fn call(c: *app_mod.App(State).Ctx, next: app_mod.Next(State)) anyerror!void {
            const st = try ensureStore(c);
            const sid_opt = readSid(c);
            const sid = if (sid_opt) |s| s else try mintSid(c);
            const sess = try c.arena.create(Session);
            sess.* = .{ .sid = sid, .store = st, .arena = c.arena };
            c.user_data = @ptrCast(sess);

            if (sid_opt == null) {
                const signed = try sign(c.arena, opts.secret, sid);
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

        fn readSid(c: *app_mod.App(State).Ctx) ?[]const u8 {
            const raw = c.req.cookie(opts.cookie_name) orelse return null;
            return verify(c.arena, opts.secret, raw) catch null;
        }

        fn mintSid(c: *app_mod.App(State).Ctx) ![]u8 {
            var raw: [16]u8 = undefined;
            // Reuse the same entropy path as auth/bcrypt (libc arc4random_buf).
            // We just call libc directly to avoid pulling that file in.
            const Rand = struct {
                extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
            };
            Rand.arc4random_buf(&raw, raw.len);
            const enc_len = b64url.Encoder.calcSize(raw.len);
            const out = try c.arena.alloc(u8, enc_len);
            _ = b64url.Encoder.encode(out, &raw);
            return out;
        }
    };
    return .{ .name = "session", .call = Impl.call };
}

pub fn currentSession(comptime State: type, c: *app_mod.App(State).Ctx) ?*Session {
    const p = c.user_data orelse return null;
    return @ptrCast(@alignCast(p));
}

// ----- Cookie signing -----

fn sign(arena: std.mem.Allocator, secret: []const u8, sid: []const u8) ![]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, sid, secret);
    const enc_len = b64url.Encoder.calcSize(mac.len);
    var out = try arena.alloc(u8, sid.len + 1 + enc_len);
    @memcpy(out[0..sid.len], sid);
    out[sid.len] = '.';
    _ = b64url.Encoder.encode(out[sid.len + 1 ..], &mac);
    return out;
}

fn verify(arena: std.mem.Allocator, secret: []const u8, signed: []const u8) ![]u8 {
    const dot = std.mem.indexOfScalar(u8, signed, '.') orelse return error.BadCookie;
    const sid_part = signed[0..dot];
    const mac_b64 = signed[dot + 1 ..];

    var expected: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected, sid_part, secret);

    var got: [HmacSha256.mac_length]u8 = undefined;
    b64url.Decoder.decode(&got, mac_b64) catch return error.BadCookie;
    if (!std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, got, expected)) {
        return error.BadCookie;
    }
    return arena.dupe(u8, sid_part);
}

test "sign/verify roundtrip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const signed = try sign(arena, "s3cr3t", "abc123");
    const back = try verify(arena, "s3cr3t", signed);
    try std.testing.expectEqualStrings("abc123", back);
}

test "verify rejects tampered signature" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var signed = try sign(arena, "s3cr3t", "abc123");
    signed[signed.len - 1] ^= 0x01;
    try std.testing.expectError(error.BadCookie, verify(arena, "s3cr3t", signed));
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
