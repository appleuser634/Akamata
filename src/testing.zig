//! In-process test client for Akamata apps.
//!
//! Skips the TCP layer entirely: builds a synthetic Request, runs it through
//! `app.dispatch`, and exposes the Response (status, headers, body) for
//! assertion. No port, no thread, no flakiness.
//!
//! Example:
//!
//!     var app = am.App(State).init(alloc, .{});
//!     defer app.deinit();
//!     _ = try app.get("/users/:id", getUser);
//!
//!     var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
//!     defer client.deinit();
//!
//!     var resp = try client.get("/users/42").bearer("token").send();
//!     defer resp.deinit();
//!     try std.testing.expectEqual(@as(u16, 200), resp.status);
//!     try resp.expectJsonField("id", "42");

const std = @import("std");
const req_mod = @import("http/request.zig");
const res_mod = @import("http/response.zig");
const status_mod = @import("http/status.zig");

pub const Header = req_mod.Header;

pub fn Client(comptime AppT: type) type {
    return struct {
        const Self = @This();
        gpa: std.mem.Allocator,
        app: *AppT,

        pub fn init(gpa: std.mem.Allocator, app: *AppT) Self {
            return .{ .gpa = gpa, .app = app };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn request(self: *Self, method: status_mod.Method, path: []const u8) RequestBuilder(AppT) {
            return .{
                .gpa = self.gpa,
                .app = self.app,
                .method = method,
                .path = path,
                .headers = .empty,
                .body_bytes = "",
                .owned_strings = .empty,
            };
        }

        pub fn get(self: *Self, path: []const u8) RequestBuilder(AppT) {
            return self.request(.GET, path);
        }
        pub fn post(self: *Self, path: []const u8) RequestBuilder(AppT) {
            return self.request(.POST, path);
        }
        pub fn put(self: *Self, path: []const u8) RequestBuilder(AppT) {
            return self.request(.PUT, path);
        }
        pub fn delete(self: *Self, path: []const u8) RequestBuilder(AppT) {
            return self.request(.DELETE, path);
        }
        pub fn patch(self: *Self, path: []const u8) RequestBuilder(AppT) {
            return self.request(.PATCH, path);
        }

        /// Formatted-path variant: `client.requestf(.DELETE, "/tasks/{d}", .{id})`
        /// allocates the path through the gpa and tracks it for cleanup
        /// when the Response is deinit-ed. Saves the
        /// `std.fmt.allocPrint + defer free + .request(...)` boilerplate
        /// that piles up in tests with dynamic URLs.
        pub fn requestf(
            self: *Self,
            method: status_mod.Method,
            comptime fmt: []const u8,
            args: anytype,
        ) RequestBuilder(AppT) {
            const path = std.fmt.allocPrint(self.gpa, fmt, args) catch unreachable;
            var b = self.request(method, path);
            b.owned_strings.append(b.gpa, path) catch unreachable;
            return b;
        }

        pub fn getf(self: *Self, comptime fmt: []const u8, args: anytype) RequestBuilder(AppT) {
            return self.requestf(.GET, fmt, args);
        }
        pub fn postf(self: *Self, comptime fmt: []const u8, args: anytype) RequestBuilder(AppT) {
            return self.requestf(.POST, fmt, args);
        }
        pub fn putf(self: *Self, comptime fmt: []const u8, args: anytype) RequestBuilder(AppT) {
            return self.requestf(.PUT, fmt, args);
        }
        pub fn deletef(self: *Self, comptime fmt: []const u8, args: anytype) RequestBuilder(AppT) {
            return self.requestf(.DELETE, fmt, args);
        }
        pub fn patchf(self: *Self, comptime fmt: []const u8, args: anytype) RequestBuilder(AppT) {
            return self.requestf(.PATCH, fmt, args);
        }
    };
}

pub fn RequestBuilder(comptime AppT: type) type {
    return struct {
        const Self = @This();
        gpa: std.mem.Allocator,
        app: *AppT,
        method: status_mod.Method,
        /// Full path including any `?query` portion. We split it on `send()`.
        path: []const u8,
        headers: std.ArrayList(Header),
        body_bytes: []const u8,
        /// Tracks header values + body that we allocated (vs caller-owned
        /// literals). The Response will free these on deinit.
        owned_strings: std.ArrayList([]const u8),

        /// Stage a header. The caller owns both `name` and `value` (typically
        /// string literals). For values that must be allocated (bearer,
        /// cookie, json content-type), use the typed helpers.
        pub fn header(self: Self, name: []const u8, value: []const u8) Self {
            var s = self;
            s.headers.append(s.gpa, .{ .name = name, .value = value }) catch unreachable;
            return s;
        }

        /// Convenience: set `Authorization: Bearer <token>`.
        pub fn bearer(self: Self, token: []const u8) Self {
            const v = std.fmt.allocPrint(self.gpa, "Bearer {s}", .{token}) catch unreachable;
            var s = self;
            s.owned_strings.append(s.gpa, v) catch unreachable;
            return s.header("authorization", v);
        }

        /// Set the raw body bytes and content-type. Both args must outlive
        /// the request (caller-owned).
        pub fn body(self: Self, content_type: []const u8, bytes: []const u8) Self {
            return self.header("content-type", content_type).rawBody(bytes);
        }

        /// Set the raw body without altering headers. Caller-owned.
        pub fn rawBody(self: Self, bytes: []const u8) Self {
            var s = self;
            s.body_bytes = bytes;
            return s;
        }

        /// JSON-encode `value` and stage it as the request body. Content-type
        /// is set to `application/json`.
        pub fn json(self: Self, value: anytype) Self {
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            std.json.Stringify.value(value, .{}, &aw.writer) catch unreachable;
            const owned = self.gpa.dupe(u8, aw.written()) catch unreachable;
            var s = self;
            s.owned_strings.append(s.gpa, owned) catch unreachable;
            s.body_bytes = owned;
            return s.header("content-type", "application/json");
        }

        /// Stage a `Cookie` header. Use `setCookie` for multiple cookies in
        /// one header (joined with `; `).
        pub fn cookie(self: Self, name: []const u8, value: []const u8) Self {
            const v = std.fmt.allocPrint(self.gpa, "{s}={s}", .{ name, value }) catch unreachable;
            var s = self;
            s.owned_strings.append(s.gpa, v) catch unreachable;
            return s.header("cookie", v);
        }

        /// Run the request through the app. Returns a Response that owns
        /// its arena and must be `.deinit()`ed.
        pub fn send(self: Self) !Response {
            var arena_state = try self.gpa.create(std.heap.ArenaAllocator);
            errdefer self.gpa.destroy(arena_state);
            arena_state.* = .init(self.gpa);
            errdefer arena_state.deinit();
            const arena = arena_state.allocator();

            // Split path on the first '?' so the query string is exposed
            // to Request.query() consumers.
            const path = self.path;
            const qi = std.mem.indexOfScalar(u8, path, '?');
            const path_only = if (qi) |i| path[0..i] else path;
            const query_only = if (qi) |i| path[i + 1 ..] else "";

            // Bake a Request whose backing data is owned by the test client.
            // Note: headers and body_bytes are not duped here — they outlive
            // the dispatch call since they're owned by `self.gpa`.
            var request: req_mod.Request = .{
                .method = self.method,
                .raw_method = @tagName(self.method),
                .path = path_only,
                .query = query_only,
                .version = "HTTP/1.1",
                .headers = self.headers.items,
                .body = self.body_bytes,
                .keep_alive = false,
            };
            var response: res_mod.Response = .init(arena);
            try self.app.dispatch(arena, &request, &response, null, null);

            return .{
                .gpa = self.gpa,
                .arena_state = arena_state,
                .status = response.status_code,
                .headers = response.headers.items,
                .body = response.body.items,
                .input_headers = self.headers,
                .owned_strings = self.owned_strings,
            };
        }
    };
}

pub const Response = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    status: u16,
    /// Borrowed from the arena. Don't outlive the Response.
    headers: []const res_mod.Header,
    /// Borrowed from the arena.
    body: []const u8,

    input_headers: std.ArrayList(Header),
    owned_strings: std.ArrayList([]const u8),

    pub fn deinit(self: *Response) void {
        for (self.owned_strings.items) |s| self.gpa.free(s);
        self.owned_strings.deinit(self.gpa);
        self.input_headers.deinit(self.gpa);
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
    }

    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Parse the body as JSON into T. Memory is owned by the response arena.
    pub fn json(self: Response, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.arena_state.allocator(), self.body, .{
            .ignore_unknown_fields = true,
        });
    }
};

// ===== factories =====

/// Tiny builder for ORM records during tests:
///
///     const user = try am.testing.factory(User, .{ .name = "alice" })
///         .create(c.db(), arena);
///
/// The first arg is the model type; the second is a partial-defaults struct
/// merged on top of any `__schema.defaults` the model declares.
pub fn factory(comptime T: type, overrides: anytype) Factory(T, @TypeOf(overrides)) {
    return .{ .overrides = overrides };
}

pub fn Factory(comptime T: type, comptime Overrides: type) type {
    return struct {
        overrides: Overrides,

        pub fn build(self: @This()) T {
            var instance: T = undefined;
            // Apply schema defaults if any.
            if (@hasDecl(T, "__schema") and @hasDecl(@TypeOf(T.__schema), "defaults")) {
                inline for (T.__schema.defaults) |kv| {
                    @field(instance, kv.field) = kv.value;
                }
            }
            // Apply caller overrides.
            inline for (@typeInfo(Overrides).@"struct".fields) |f| {
                @field(instance, f.name) = @field(self.overrides, f.name);
            }
            return instance;
        }

        /// Insert through the Repo.
        pub fn create(
            self: @This(),
            db: anytype,
            arena: std.mem.Allocator,
        ) !T {
            const repo = @import("model/model.zig").repo(T);
            const built = self.build();
            return repo.create(db, arena, built);
        }
    };
}
