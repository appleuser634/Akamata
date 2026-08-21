const std = @import("std");
const req_mod = @import("http/request.zig");
const res_mod = @import("http/response.zig");
const json_mod = @import("json.zig");
const multipart_mod = @import("http/multipart.zig");
const form_mod = @import("http/form.zig");
const cookie_mod = @import("http/cookie.zig");
const trace_mod = @import("observability/trace.zig");
const db_mod = @import("db/db.zig");
const http_client = @import("http_client.zig");

pub const ParamError = error{
    MissingParam,
    InvalidParam,
};

/// Build a "projection" of `T` where every field is optional and defaults
/// to null. Used by `c.input` to parse user JSON permissively — fields
/// the client omitted come through as null, which the validator surfaces
/// as a 422 (via the `required` rule) instead of std.json's 400-level
/// `error.MissingField`.
///
/// Comptime-only; no runtime cost.
fn projectionOf(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") return T;
    const src_fields = info.@"struct".fields;
    var names: [src_fields.len][]const u8 = undefined;
    var types: [src_fields.len]type = undefined;
    var attrs: [src_fields.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (src_fields, 0..) |f, i| {
        // Already optional? Keep as-is. Otherwise wrap in ?T.
        const Ft = if (@typeInfo(f.type) == .optional) f.type else ?f.type;
        const null_default: Ft = null;
        names[i] = f.name;
        types[i] = Ft;
        attrs[i] = .{ .default_value_ptr = @ptrCast(&null_default) };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Lift a projection back into `T`. For each T field:
///   - if the projection has a non-null value → use it
///   - else if T has a default value → use that
///   - else → leave the field at its zero / undefined state. This branch
///     is reachable only when the validator was already supposed to fire
///     a 422 (i.e. you've called `c.input(T)` without listing `required`
///     for a non-optional, no-default field); the resulting struct is
///     never observed by the caller because `c.input` already early-
///     returned.
fn liftProjection(comptime T: type, proj: anytype) T {
    const info = @typeInfo(T);
    if (info != .@"struct") return proj;
    var out: T = undefined;
    inline for (info.@"struct".fields) |f| {
        const proj_value = @field(proj, f.name);
        if (@typeInfo(f.type) == .optional) {
            // T's field is already optional — copy as-is.
            @field(out, f.name) = proj_value;
        } else {
            if (proj_value) |v| {
                @field(out, f.name) = v;
            } else if (f.defaultValue()) |dv| {
                @field(out, f.name) = dv;
            } else {
                @field(out, f.name) = std.mem.zeroes(f.type);
            }
        }
    }
    return out;
}

pub const Params = struct {
    names: []const []const u8 = &.{},
    values: []const []const u8 = &.{},

    pub fn get(self: Params, name: []const u8) ?[]const u8 {
        for (self.names, self.values) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    pub fn expect(self: Params, comptime T: type, name: []const u8) ParamError!T {
        const raw = self.get(name) orelse return ParamError.MissingParam;
        return parse(T, raw);
    }

    fn parse(comptime T: type, s: []const u8) ParamError!T {
        const info = @typeInfo(T);
        return switch (info) {
            .int => std.fmt.parseInt(T, s, 10) catch return ParamError.InvalidParam,
            .float => std.fmt.parseFloat(T, s) catch return ParamError.InvalidParam,
            .pointer => |p| if (p.size == .slice and p.child == u8) @as(T, s) else @compileError("Params.expect: unsupported pointer type"),
            else => @compileError("Params.expect: unsupported type " ++ @typeName(T)),
        };
    }
};

/// Hono-style wrapper around the parsed HTTP request. Lifetime is the same as
/// the surrounding `Context` (per-request arena).
pub fn Req(comptime State: type) type {
    _ = State;
    return struct {
        const Self = @This();

        inner: *req_mod.Request,
        params_ref: *const Params,
        arena: std.mem.Allocator,
        /// Direct peer address (socket-level), populated by the native HTTP
        /// server. Null on Workers, or when the server didn't record one.
        peer_ip: ?[]const u8 = null,
        trust_proxy_headers: bool = false,

        pub fn method(self: Self) []const u8 {
            return @tagName(self.inner.method);
        }
        pub fn path(self: Self) []const u8 {
            return self.inner.path;
        }

        /// Return the request path with `%XX` escapes decoded. Allocated in
        /// the per-request arena. `%00` is preserved as a NUL byte — handlers
        /// that pass the result to filesystem or shell APIs must validate it.
        pub fn pathDecoded(self: Self) ![]u8 {
            return percentDecode(self.arena, self.inner.path);
        }
        pub fn body(self: Self) []const u8 {
            return self.inner.body;
        }
        pub fn text(self: Self) []const u8 {
            return self.inner.body;
        }
        pub fn header(self: Self, name: []const u8) ?[]const u8 {
            return self.inner.header(name);
        }

        /// Single path parameter (string). Returns error if missing.
        pub fn param(self: Self, name: []const u8) ParamError![]const u8 {
            return self.params_ref.get(name) orelse ParamError.MissingParam;
        }

        /// Typed path parameter. Use `c.req.paramAs(u64, "id")` etc.
        pub fn paramAs(self: Self, comptime T: type, name: []const u8) ParamError!T {
            return self.params_ref.expect(T, name);
        }

        /// First value for a query parameter (`?foo=bar`).
        pub fn query(self: Self, name: []const u8) ?[]const u8 {
            return findQuery(self.inner.query, name);
        }

        /// All values for a repeated query parameter. Allocates in the arena.
        pub fn queries(self: Self, name: []const u8) ![]const []const u8 {
            var out: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, self.inner.query, '&');
            while (it.next()) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                if (std.mem.eql(u8, kv[0..eq], name)) {
                    try out.append(self.arena, kv[eq + 1 ..]);
                }
            }
            return out.toOwnedSlice(self.arena);
        }

        /// Parse the JSON body into `T` using the per-request arena.
        pub fn json(self: Self, comptime T: type) !T {
            return json_mod.parseLeaky(T, self.arena, self.inner.body);
        }

        /// Parse `application/x-www-form-urlencoded` body.
        pub fn form(self: Self) !form_mod.Form {
            return form_mod.parse(self.arena, self.inner.body);
        }

        /// Parse `multipart/form-data` body. Returns the parsed parts. The
        /// boundary is taken from the `Content-Type` header automatically;
        /// callers can `c.req.multipart()` and inspect `parts` by name.
        pub fn multipart(self: Self) !multipart_mod.Parsed {
            const ct = self.inner.header("content-type") orelse return error.MissingContentType;
            const boundary = multipart_mod.boundaryFromContentType(ct) orelse return error.MissingBoundary;
            return multipart_mod.parse(self.arena, self.inner.body, boundary);
        }

        /// Look up a request cookie by name (parses `Cookie:` header).
        pub fn cookie(self: Self, name: []const u8) ?[]const u8 {
            const raw = self.inner.header("cookie") orelse return null;
            return cookie_mod.parseHeader(raw, name);
        }

        /// Client IP. Forwarding headers are considered only when explicitly
        /// trusted by the server; otherwise only the direct peer is used.
        /// Returns null when the target does not provide peer metadata.
        pub fn ip(self: Self) ?[]const u8 {
            if (!self.trust_proxy_headers) return self.peer_ip;
            if (self.inner.header("x-forwarded-for")) |xff| {
                // Take the first non-empty element.
                var it = std.mem.splitScalar(u8, xff, ',');
                while (it.next()) |part| {
                    const t = std.mem.trim(u8, part, " \t");
                    if (t.len > 0) return t;
                }
            }
            if (self.inner.header("cf-connecting-ip")) |cf| return cf;
            if (self.inner.header("x-real-ip")) |r| return r;
            return self.peer_ip;
        }
    };
}

fn findQuery(qs: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return null;
}

/// Hono-style per-request handle. Generic over the app's `State` type so handlers
/// can do `c.state().db` etc. without unsafe casts.
pub fn Context(comptime State: type) type {
    return struct {
        const Self = @This();
        pub const Request = Req(State);

        req: Request,
        res: *res_mod.Response,
        arena: std.mem.Allocator,
        params: Params,
        app_state: *State,
        /// Request-scoped observability state. It is embedded in Context, so
        /// it follows the arena/request lifetime and never competes with
        /// middleware `user_data`.
        trace: trace_mod.TraceContext = .{},
        /// Reserved for middleware-to-handler data passing (e.g. JWT claims).
        user_data: ?*anyopaque = null,
        auth_data: ?*anyopaque = null,
        principal_data: ?*anyopaque = null,
        session_data: ?*anyopaque = null,
        /// State owned by the currently executing middleware registration.
        /// Middleware factories use this to keep mutable state App-local.
        middleware_data: ?*anyopaque = null,
        /// WS upgrade plumbing — populated by the server.
        stream_ptr: ?*anyopaque = null,
        io_ptr: ?*anyopaque = null,
        /// Back-pointer to the `am.App(State)` that dispatched this
        /// request. Type-erased so `Context(State)` doesn't have to refer
        /// to its parent type (which would create a recursive definition).
        /// Recover via `c.app()` from the handler.
        app_ref: ?*anyopaque = null,

        pub fn state(self: *Self) *State {
            return self.app_state;
        }

        /// Attach a typed browser/device/service principal for this request.
        /// Storage is request-owned; existing JWT auth_data remains intact.
        pub fn setPrincipal(self: *Self, value_to_attach: anytype) !void {
            const T = @TypeOf(value_to_attach);
            const value = try self.arena.create(T);
            value.* = value_to_attach;
            self.principal_data = value;
        }

        pub fn principal(self: *Self, comptime T: type) ?*const T {
            const erased = self.principal_data orelse return null;
            return @ptrCast(@alignCast(erased));
        }

        /// Explicit name for the allocator whose allocations live until the
        /// end of this request. `arena` remains public for compatibility.
        pub fn requestAllocator(self: *Self) std.mem.Allocator {
            return self.arena;
        }

        /// Copy borrowed request bytes into request-owned storage when data
        /// must survive parsing or mutation within the handler pipeline.
        pub fn ownRequestBytes(self: *Self, borrowed: []const u8) ![]u8 {
            return self.arena.dupe(u8, borrowed);
        }

        /// Return the framework's `*am.App(State)`. Useful for handlers
        /// that need to introspect the route table at request time —
        /// `am.openapi.generate(...)` and `am.client_gen.generate(...)`
        /// take this directly.
        ///
        /// Returns null only if the Context was constructed manually
        /// (e.g. in a unit test that bypasses `app.dispatch`).
        pub fn app(self: *Self) ?*@import("app.zig").App(State) {
            const erased = self.app_ref orelse return null;
            return @ptrCast(@alignCast(erased));
        }

        // ===== Shortcuts to common State fields =====
        //
        // Most apps put their DB handle on `State.db` and their config on
        // `State.cfg`. These helpers save `ctx.state().db` repetition; if the
        // field doesn't exist on State, the call becomes a compile error
        // pointing right at the missing field.

        /// `c.db()` ≡ `c.state().db`. Compile-time error if State has no `db`.
        pub fn db(self: *Self) if (@TypeOf(self.app_state.db) == db_mod.Db) db_mod.Db else @TypeOf(self.app_state.db) {
            if (comptime @TypeOf(self.app_state.db) == db_mod.Db) {
                return self.app_state.db.observed(&self.trace);
            }
            return self.app_state.db;
        }

        /// Stable request ID installed by `am.mw.requestId`, independent of
        /// `user_data` used by sessions/JWT middleware.
        pub fn requestId(self: *const Self) ?[]const u8 {
            return self.trace.requestId();
        }

        /// The registered route template, never the raw dynamic URL.
        pub fn routePattern(self: *const Self) ?[]const u8 {
            return self.trace.route_pattern;
        }

        /// Start an allocation-free request span. Prefer static names and
        /// always pair with `defer span.end()`.
        pub fn startSpan(self: *Self, name: []const u8) trace_mod.Span {
            return self.trace.startSpan(name);
        }

        /// Instrumented outbound HTTP. Full URLs are never retained or used
        /// as labels; request count/duration/error are request aggregates.
        pub fn fetch(self: *Self, request: http_client.Request) http_client.HttpClientError!http_client.Response {
            return http_client.sendObserved(&self.trace, self.arena, request);
        }

        /// `c.cfg()` ≡ `c.state().cfg`. Compile-time error if State has no `cfg`.
        pub fn cfg(self: *Self) @TypeOf(self.app_state.cfg) {
            return self.app_state.cfg;
        }

        // ===== Input parse + validate =====

        /// Parse the JSON body into `T` and (if `T` has a `__schema.validates`
        /// declaration) run model validators against it. The non-happy path
        /// is fully encapsulated:
        ///
        ///   * malformed JSON → writes 400 and returns null
        ///   * missing required fields → 422 with field-level errors
        ///   * validation errors → 422 with the error list
        ///
        /// Idiomatic use in handlers:
        ///
        ///     pub fn create(c: *Ctx) !void {
        ///         const entry = (try c.input(Entry)) orelse return;
        ///         const created = try Entries.create(c.db(), c.arena, entry);
        ///         try c.json(created, 201);
        ///     }
        ///
        /// If you want the raw error, use `c.req.json(T)` + `am.model.validate`.
        pub fn input(self: *Self, comptime T: type) !?T {
            // Parse permissively: build a comptime projection of T where
            // every field is optional, parse the body into *that*, then
            // run validators. This way a body of `{}` against a struct
            // with required fields surfaces as a clean 422 with field-
            // level errors, not a 400 "invalid JSON body".
            const Projection = projectionOf(T);
            const proj = self.req.json(Projection) catch {
                try self.badRequest("invalid JSON body");
                return null;
            };

            // Zig's type is authoritative: a non-optional field without a
            // default is required even when the model omitted an explicit
            // validation rule. Never manufacture zero values for missing
            // input, especially for pointers and enums.
            var missing: std.ArrayList(@import("model/validate.zig").ValidationError) = .empty;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (@typeInfo(f.type) != .optional and f.defaultValue() == null and @field(proj, f.name) == null) {
                    try missing.append(self.arena, .{
                        .field = f.name,
                        .rule = .required,
                        .message = "is required",
                    });
                }
            }
            if (missing.items.len > 0) {
                try self.unprocessable(missing.items);
                return null;
            }

            if (@hasDecl(T, "__schema")) {
                const errs = try @import("model/validate.zig").validateAny(T, proj, self.arena);
                if (errs.len > 0) {
                    try self.unprocessable(errs);
                    return null;
                }
            }

            // Lift projection → T. Fields that were absent in the JSON
            // become the projection's null; we use T's struct-level
            // defaults for those. If a non-optional T field is null in
            // the projection AND has no default, that's a 422 the
            // validator should have already raised (via `required`) —
            // we fall through with a zero-value to keep this fn total.
            return liftProjection(T, proj);
        }

        // ===== Response helpers =====

        pub fn status(self: *Self, code: u16) void {
            self.res.setStatus(code);
        }

        pub fn header(self: *Self, name: []const u8, value: []const u8) !void {
            try self.res.header(name, value);
        }

        /// Append a `Set-Cookie` header. Multiple calls add multiple cookies.
        pub fn setCookie(self: *Self, name: []const u8, value: []const u8, opts: cookie_mod.Options) !void {
            const sc = try cookie_mod.build(self.arena, name, value, opts);
            try self.res.header("set-cookie", sc);
        }

        pub fn body(self: *Self, bytes: []const u8) !void {
            try self.res.writeAll(bytes);
        }

        pub fn json(self: *Self, value: anytype, code: u16) !void {
            self.res.setStatus(code);
            try self.res.json(value);
        }

        pub fn text(self: *Self, content: []const u8) !void {
            try self.res.text(content);
        }

        pub fn html(self: *Self, content: []const u8) !void {
            try self.res.html(content);
        }

        pub fn redirect(self: *Self, location: []const u8, code: u16) !void {
            self.res.setStatus(code);
            try self.res.header("location", location);
        }

        /// Switch to streaming mode. Headers + status are flushed
        /// immediately and the returned writer frames every flush as one
        /// HTTP/1.1 chunk. See `src/http/response.zig` for the full
        /// contract.
        pub fn startStream(self: *Self, opts: res_mod.StreamOptions) !*std.Io.Writer {
            return self.res.startStream(opts);
        }

        /// Pick the best media type for this request from a server-side
        /// allow-list. Returns null if the client's Accept header refuses
        /// every candidate (RFC: respond 406 in that case).
        ///
        /// Example:
        ///     const mt = c.negotiate(&.{ "application/json", "text/html" })
        ///         orelse return c.json(.{ .error_kind = "not_acceptable" }, 406);
        ///     if (std.mem.eql(u8, mt, "text/html")) try c.html(...) else try c.json(...);
        pub fn negotiate(self: *Self, candidates: []const []const u8) ?[]const u8 {
            const accept = self.req.header("accept");
            return @import("negotiate.zig").best(accept, candidates);
        }

        pub fn notFound(self: *Self) !void {
            self.res.setStatus(404);
            try self.res.json(.{ .error_kind = "not_found", .path = self.req.path() });
        }

        // ===== Error response shortcuts =====
        //
        // Idiomatic shape: `return c.badRequest("expected name/message")`. All
        // helpers emit the same `{ error_kind, message? }` envelope so clients
        // can rely on the shape across handlers.

        /// 400 — request body or params don't make sense for this endpoint.
        pub fn badRequest(self: *Self, msg: []const u8) !void {
            self.res.setStatus(400);
            try self.res.json(.{ .error_kind = "bad_request", .message = msg });
        }

        /// 401 — caller is not authenticated.
        pub fn unauthorized(self: *Self, msg: []const u8) !void {
            self.res.setStatus(401);
            try self.res.json(.{ .error_kind = "unauthorized", .message = msg });
        }

        /// 403 — caller is authenticated but not allowed.
        pub fn forbidden(self: *Self, msg: []const u8) !void {
            self.res.setStatus(403);
            try self.res.json(.{ .error_kind = "forbidden", .message = msg });
        }

        /// 409 — request would conflict with current state (e.g. duplicate
        /// resource).
        pub fn conflict(self: *Self, msg: []const u8) !void {
            self.res.setStatus(409);
            try self.res.json(.{ .error_kind = "conflict", .message = msg });
        }

        /// 422 — semantic / validation errors. Pass the validation error list
        /// (or any struct) as `details`.
        pub fn unprocessable(self: *Self, details: anytype) !void {
            self.res.setStatus(422);
            try self.res.json(.{ .error_kind = "validation", .errors = details });
        }

        /// 500 — generic server error; prefer letting middleware (`recover`)
        /// handle this, but exposed for explicit branches.
        pub fn serverError(self: *Self, msg: []const u8) !void {
            self.res.setStatus(500);
            try self.res.json(.{ .error_kind = "internal", .message = msg });
        }

        // ===== Legacy compat (existing handlers in examples) =====

        /// Set a typed value into `user_data`. The pointer must remain valid
        /// for the request's arena lifetime — typical use is `c.arena.create(T)`.
        pub fn setUser(self: *Self, ptr: anytype) void {
            self.user_data = @ptrCast(@constCast(ptr));
        }

        pub fn getUser(self: *Self, comptime T: type) ?*T {
            const p = self.user_data orelse return null;
            return @ptrCast(@alignCast(p));
        }
    };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => null,
    };
}

fn percentDecode(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(arena, src.len);
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '%' and i + 2 < src.len) {
            const hi = hexNibble(src[i + 1]) orelse {
                try out.append(arena, src[i]);
                continue;
            };
            const lo = hexNibble(src[i + 2]) orelse {
                try out.append(arena, src[i]);
                continue;
            };
            try out.append(arena, (hi << 4) | lo);
            i += 2;
        } else if (src[i] == '+') {
            // `+` is only special inside query strings; leave it alone in paths.
            try out.append(arena, '+');
        } else {
            try out.append(arena, src[i]);
        }
    }
    return out.toOwnedSlice(arena);
}

test "percentDecode handles ASCII and unicode escapes" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings("hello world", try percentDecode(arena, "hello%20world"));
    try t.expectEqualStrings("/users/42", try percentDecode(arena, "%2Fusers%2F42"));
    try t.expectEqualStrings("日本", try percentDecode(arena, "%E6%97%A5%E6%9C%AC"));
    // Invalid escapes are preserved verbatim.
    try t.expectEqualStrings("%zz", try percentDecode(arena, "%zz"));
}
