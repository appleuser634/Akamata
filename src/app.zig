// Hono-style App. Routes, middlewares, and groupings are accumulated at
// runtime via builder methods. `App(MyState)` is generic over the user-defined
// state type, and handlers receive `*Context(State)`.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const ctx_mod = @import("context.zig");
const req_mod = @import("http/request.zig");
const res_mod = @import("http/response.zig");
const status_mod = @import("http/status.zig");
const parser = @import("http/parser.zig");

pub const Method = status_mod.Method;
pub const RouteKind = enum { http, ws };

pub fn Handler(comptime State: type) type {
    return *const fn (c: *ctx_mod.Context(State)) anyerror!void;
}

pub fn ErrorHandler(comptime State: type) type {
    return *const fn (err: anyerror, c: *ctx_mod.Context(State)) anyerror!void;
}

pub fn Middleware(comptime State: type) type {
    return struct {
        name: []const u8 = "anon",
        call: *const fn (c: *ctx_mod.Context(State), next: Next(State)) anyerror!void,
    };
}

pub fn Next(comptime State: type) type {
    return struct {
        const Self = @This();
        chain: []const Entry,
        terminal: Handler(State),
        index: usize,

        pub const Entry = struct {
            mw: Middleware(State),
            /// Pattern this mw applies to. Empty = global.
            pattern: []const u8 = "",
        };

        pub fn run(self: Self, c: *ctx_mod.Context(State)) anyerror!void {
            var i = self.index;
            while (i < self.chain.len) : (i += 1) {
                const entry = self.chain[i];
                if (entry.pattern.len == 0 or patternMatches(entry.pattern, c.req.path())) {
                    const next: Self = .{
                        .chain = self.chain,
                        .terminal = self.terminal,
                        .index = i + 1,
                    };
                    return entry.mw.call(c, next);
                }
            }
            return self.terminal(c);
        }
    };
}

/// Simple glob: `prefix/*` matches anything starting with `prefix/`, and a bare
/// path matches itself. No `**`.
fn patternMatches(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return true;
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const head = pattern[0 .. pattern.len - 1]; // keep trailing '/'
        return std.mem.startsWith(u8, path, head);
    }
    if (pattern[pattern.len - 1] == '*') {
        const head = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, path, head);
    }
    return std.mem.eql(u8, pattern, path);
}

// ===== Runtime route storage =====

const SegKind = enum { static, param, wildcard };
const Segment = struct {
    kind: SegKind,
    text: []const u8,
};

fn parseSegments(gpa: std.mem.Allocator, path: []const u8) ![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    var p = path;
    if (p.len > 0 and p[0] == '/') p = p[1..];
    if (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    if (p.len == 0) return segs.toOwnedSlice(gpa);
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        const kind: SegKind = if (seg.len > 0 and seg[0] == ':')
            .param
        else if (seg.len > 0 and seg[0] == '*')
            .wildcard
        else
            .static;
        const text: []const u8 = switch (kind) {
            .static => seg,
            .param, .wildcard => if (seg.len > 0) seg[1..] else "_",
        };
        try segs.append(gpa, .{ .kind = kind, .text = text });
    }
    return segs.toOwnedSlice(gpa);
}

fn matchSegments(
    seg_tpl: []const Segment,
    path: []const u8,
    name_buf: [][]const u8,
    value_buf: [][]const u8,
) ?ctx_mod.Params {
    var p = path;
    if (p.len > 0 and p[0] == '/') p = p[1..];
    if (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];

    var n: usize = 0;
    var i: usize = 0;
    var path_pos: usize = 0;
    while (i < seg_tpl.len) : (i += 1) {
        const s = seg_tpl[i];
        if (s.kind == .wildcard) {
            if (n >= name_buf.len) return null;
            name_buf[n] = if (s.text.len == 0) "_" else s.text;
            value_buf[n] = p[path_pos..];
            n += 1;
            return .{ .names = name_buf[0..n], .values = value_buf[0..n] };
        }
        // Find next slash in path
        const remaining = p[path_pos..];
        const end = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
        if (end == 0 and remaining.len == 0) return null;
        const piece = remaining[0..end];
        switch (s.kind) {
            .static => if (!std.mem.eql(u8, s.text, piece)) return null,
            .param => {
                if (n >= name_buf.len) return null;
                name_buf[n] = s.text;
                value_buf[n] = piece;
                n += 1;
            },
            .wildcard => unreachable,
        }
        path_pos += end;
        if (path_pos < p.len and p[path_pos] == '/') path_pos += 1;
    }
    // All template segments consumed; path must also be fully consumed.
    if (path_pos < p.len) return null;
    return .{ .names = name_buf[0..n], .values = value_buf[0..n] };
}

// ===== App =====

pub const Runtime = enum {
    /// Default — std.Io.Threaded + one accept loop per worker. Solid,
    /// portable, but bounded by `accept_thread_count` for concurrency.
    threaded,
    /// Prototype kqueue-based reactor (PERF2). macOS / BSD only for now.
    /// Better keep-alive density, single-thread event loop. Opt-in until
    /// the full A/B benchmark suite says we should flip the default.
    reactor,
};

pub const ServeOptions = struct {
    address: ?[]const u8 = null,
    port: u16 = 8080,
    accept_thread_count: usize = 4,
    /// HTTP runtime selection. `.threaded` is the current production
    /// model; `.reactor` is the new kqueue-based prototype (BSD-family
    /// kernels only). See `docs/perf-reactor-design.md`.
    runtime: Runtime = .threaded,
    /// Number of worker threads when `runtime == .reactor`. `null` =
    /// `std.Thread.getCpuCount()` (default). Has no effect on the
    /// threaded runtime, which uses `accept_thread_count` instead.
    worker_count: ?usize = null,
    /// Per-connection read timeout in milliseconds. **Currently unused** —
    /// the previous SO_RCVTIMEO-based implementation conflicted with Zig
    /// 0.16's std.Io.Threaded (which treats EAGAIN as a programmer bug and
    /// panics). Field is kept so a future non-stdlib read path can honour
    /// it without breaking callers' ServeOptions literals. See the comment
    /// block in src/serve.zig for the full rationale.
    read_timeout_ms: u32 = 30_000,
    /// Per-connection write timeout in milliseconds. See `read_timeout_ms`
    /// note above — currently unused.
    write_timeout_ms: u32 = 30_000,
};

pub fn App(comptime State: type) type {
    return struct {
        const Self = @This();
        pub const Ctx = ctx_mod.Context(State);
        pub const H = Handler(State);
        pub const EH = ErrorHandler(State);
        pub const Mw = Middleware(State);

        gpa: std.mem.Allocator,
        state_value: State,
        base_prefix: []const u8 = "",
        routes: std.ArrayList(Route) = .empty,
        middlewares: std.ArrayList(Next(State).Entry) = .empty,
        not_found_handler: ?H = null,
        err_handler: ?EH = null,
        /// Optimisation: routes with only static segments are stored in a
        /// `"METHOD path"` -> route index map for O(1) lookup. Routes that
        /// contain `:param` or `*rest` fall back to linear scan in `routes`.
        /// Built lazily on the first request to allow registration to keep
        /// happening up to `serve()`.
        static_index: std.StringHashMap(usize) = undefined,
        index_built: bool = false,
        /// Set by `requestShutdown()`. Read by the accept loop on every
        /// iteration; once true, the listener is closed and the loop returns.
        shutdown_flag: std.atomic.Value(bool) = .init(false),
        /// Listener socket fd, set by serve() while the loop is running.
        /// Used by `requestShutdown()` to close the fd from another thread
        /// (which makes `accept()` return `error.SocketNotListening`).
        listener_fd: std.atomic.Value(i32) = .init(-1),

        /// Heap resources whose lifetime should match the App's. Most apps
        /// have at least an event channel + a job queue here; using `own`
        /// keeps the destructor logic out of the user's `main.zig`.
        owned: std.ArrayList(OwnedEntry) = .empty,

        const OwnedEntry = struct {
            ptr: *anyopaque,
            /// Called by `app.deinit()` before the App's own resources are
            /// freed. Implementations typically call the value's deinit
            /// (if any) and then `gpa.destroy(ptr)`.
            cleanup: *const fn (gpa: std.mem.Allocator, ptr: *anyopaque) void,
        };

        const Route = struct {
            method: Method,
            kind: RouteKind,
            path: []const u8, // owned by gpa
            segments: []Segment, // owned by gpa
            handler: H,
            /// Optional OpenAPI metadata, populated by `app.endpoint(...)`.
            /// Routes registered via `app.get/post/...` leave this null and
            /// are simply omitted from the generated spec.
            meta: ?*const @import("openapi.zig").EndpointMeta = null,
        };

        /// Public, read-only view of a registered route. Used by tooling
        /// like `am.openapi.generate` and `am.client_gen.generate` so they
        /// don't have to reach into the App's private route table.
        pub const RouteView = struct {
            method: Method,
            kind: RouteKind,
            path: []const u8,
            meta: ?*const @import("openapi.zig").EndpointMeta,
        };

        /// Snapshot of every registered route. The returned slice is
        /// borrowed from the App and is invalidated by any subsequent
        /// `app.get/post/.../endpoint` call; allocate first if you need
        /// to hold onto it across registrations.
        pub fn routeViews(self: *const Self, arena: std.mem.Allocator) ![]const RouteView {
            var out = try arena.alloc(RouteView, self.routes.items.len);
            for (self.routes.items, 0..) |r, i| {
                out[i] = .{
                    .method = r.method,
                    .kind = r.kind,
                    .path = r.path,
                    .meta = r.meta,
                };
            }
            return out;
        }

        /// Number of registered routes (incl. WS). O(1).
        pub fn routeCount(self: *const Self) usize {
            return self.routes.items.len;
        }

        pub fn init(gpa: std.mem.Allocator, initial_state: State) Self {
            return .{
                .gpa = gpa,
                .state_value = initial_state,
                .static_index = std.StringHashMap(usize).init(gpa),
            };
        }

        pub fn deinit(self: *Self) void {
            // Owned resources go first — they may reference the routes
            // table (e.g. a job worker holding the DB used by handlers).
            // Iterate in reverse so destructor order is the inverse of
            // ownership order, matching how `defer` would have done it.
            var i = self.owned.items.len;
            while (i > 0) {
                i -= 1;
                const e = self.owned.items[i];
                e.cleanup(self.gpa, e.ptr);
            }
            self.owned.deinit(self.gpa);

            if (self.index_built) {
                var it = self.static_index.iterator();
                while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
            }
            self.static_index.deinit();
            for (self.routes.items) |r| {
                self.gpa.free(r.path);
                self.gpa.free(r.segments);
            }
            self.routes.deinit(self.gpa);
            for (self.middlewares.items) |entry| {
                if (entry.pattern.len > 0) self.gpa.free(entry.pattern);
            }
            self.middlewares.deinit(self.gpa);
        }

        /// Tie a heap-allocated resource's lifetime to this App. On
        /// `app.deinit()`, owned entries are destroyed in reverse
        /// registration order. The pointer's value type must have either
        /// a `deinit(*Self)` or `deinit(*Self, std.mem.Allocator)` method
        /// — both are auto-detected; if neither is present we just call
        /// `gpa.destroy(ptr)`.
        ///
        /// Idiomatic use:
        ///
        ///     const events = try alloc.create(EventChannel);
        ///     events.* = EventChannel.init(alloc);
        ///     try app.own(events);
        ///     state.events = events;
        pub fn own(self: *Self, ptr: anytype) !void {
            const Ptr = @TypeOf(ptr);
            const ti = @typeInfo(Ptr);
            if (ti != .pointer or ti.pointer.size != .one) {
                @compileError("app.own expects a single-item pointer, got " ++ @typeName(Ptr));
            }
            const Child = ti.pointer.child;

            const Cleanup = struct {
                fn cleanup(gpa: std.mem.Allocator, erased: *anyopaque) void {
                    const p: *Child = @ptrCast(@alignCast(erased));
                    if (@hasDecl(Child, "deinit")) {
                        const Fn = @TypeOf(Child.deinit);
                        const info = @typeInfo(Fn);
                        // deinit(*Self) and deinit(*Self, Allocator) are
                        // the two shapes we know how to call.
                        switch (info.@"fn".params.len) {
                            1 => p.deinit(),
                            2 => p.deinit(gpa),
                            else => {}, // unknown signature; skip
                        }
                    }
                    gpa.destroy(p);
                }
            };

            try self.owned.append(self.gpa, .{
                .ptr = @ptrCast(ptr),
                .cleanup = Cleanup.cleanup,
            });
        }

        /// Signal a running `serve()` to stop accepting new connections.
        /// Existing in-flight requests are allowed to complete; the listener
        /// socket is closed so `accept()` returns and the loop exits.
        ///
        /// Safe to call from a signal handler or a separate thread.
        pub fn requestShutdown(self: *Self) void {
            self.shutdown_flag.store(true, .seq_cst);
            const fd = self.listener_fd.load(.seq_cst);
            if (fd >= 0) {
                // shutdown() unblocks accept() without race-y close-then-reopen.
                // SHUT_RDWR = 2.
                const Sys = struct {
                    extern "c" fn shutdown(s: c_int, how: c_int) c_int;
                };
                _ = Sys.shutdown(fd, 2);
            }
        }

        pub fn state(self: *Self) *State {
            return &self.state_value;
        }

        // ===== Route registration =====

        pub fn get(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.GET, .http, path, h);
        }
        pub fn post(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.POST, .http, path, h);
        }
        pub fn put(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.PUT, .http, path, h);
        }
        pub fn delete(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.DELETE, .http, path, h);
        }
        pub fn patch(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.PATCH, .http, path, h);
        }
        pub fn options(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.OPTIONS, .http, path, h);
        }
        pub fn ws(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.GET, .ws, path, h);
        }
        /// Register the same handler for every HTTP method.
        pub fn all(self: *Self, path: []const u8, h: H) !*Self {
            inline for ([_]Method{ .GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS }) |m| {
                _ = try self.add(m, .http, path, h);
            }
            return self;
        }

        fn add(self: *Self, method: Method, kind: RouteKind, path_in: []const u8, h: H) !*Self {
            return self.addWithMeta(method, kind, path_in, h, null);
        }

        fn addWithMeta(
            self: *Self,
            method: Method,
            kind: RouteKind,
            path_in: []const u8,
            h: H,
            meta: ?*const @import("openapi.zig").EndpointMeta,
        ) !*Self {
            const full_path = try concatPath(self.gpa, self.base_prefix, path_in);
            errdefer self.gpa.free(full_path);
            const segs = try parseSegments(self.gpa, full_path);
            try self.routes.append(self.gpa, .{
                .method = method,
                .kind = kind,
                .path = full_path,
                .segments = segs,
                .handler = h,
                .meta = meta,
            });
            return self;
        }

        /// Register an HTTP endpoint with OpenAPI metadata. The same handler
        /// could equally well be registered with `app.get(path, handler)` —
        /// the difference is that `endpoint` records the request / response
        /// types so `am.openapi.generate(app)` can include this route in the
        /// generated spec.
        ///
        /// Use `am.openapi.Spec(.{ .request = T, .response = U, .summary = "..." })`
        /// to build the metadata. The result is a `*const EndpointMeta`
        /// pointing to comptime-static memory.
        pub fn endpoint(
            self: *Self,
            method: Method,
            path: []const u8,
            h: H,
            meta: *const @import("openapi.zig").EndpointMeta,
        ) !*Self {
            return self.addWithMeta(method, .http, path, h, meta);
        }

        // ===== Middlewares =====

        /// Path-scoped middleware. Use trailing `*` for prefix matches.
        pub fn use(self: *Self, pattern: []const u8, mw: Mw) !*Self {
            const full = try concatPath(self.gpa, self.base_prefix, pattern);
            try self.middlewares.append(self.gpa, .{ .mw = mw, .pattern = full });
            return self;
        }

        /// Global middleware (runs before every handler).
        pub fn useAll(self: *Self, mw: Mw) !*Self {
            try self.middlewares.append(self.gpa, .{ .mw = mw, .pattern = "" });
            return self;
        }

        // ===== Grouping =====

        /// Returns a borrowed view of `self` that prepends `prefix` to any
        /// subsequently registered routes/middlewares. The view aliases the
        /// underlying storage, so groups share routes and state.
        pub fn basePath(self: *Self, prefix: []const u8) !*Self {
            // Allocate a child App on the same arena that aliases routes/state.
            const child = try self.gpa.create(Self);
            child.* = .{
                .gpa = self.gpa,
                .state_value = undefined, // unused; we'll proxy state()
                .base_prefix = try concatPath(self.gpa, self.base_prefix, prefix),
                .routes = self.routes,
                .middlewares = self.middlewares,
                .not_found_handler = self.not_found_handler,
                .err_handler = self.err_handler,
            };
            // Provide a back-reference for state access.
            // (Implementation note: callers should not deinit a basePath result.)
            return child;
        }

        // ===== Hooks =====

        pub fn notFound(self: *Self, h: H) void {
            self.not_found_handler = h;
        }

        pub fn onError(self: *Self, h: EH) void {
            self.err_handler = h;
        }

        // ===== Dispatch =====

        /// Build a Context, run the matched handler with the middleware chain,
        /// and emit the response into `out`. Used by both native and workers.
        pub fn dispatch(
            self: *Self,
            arena: std.mem.Allocator,
            request: *req_mod.Request,
            response: *res_mod.Response,
            stream_ptr: ?*anyopaque,
            io_ptr: ?*anyopaque,
        ) !void {
            var name_buf: [16][]const u8 = undefined;
            var value_buf: [16][]const u8 = undefined;

            // Build the static-route index lazily on first request. If the
            // build fails (OOM), the linear fallback below still works, so
            // we log a warning rather than failing the request.
            if (!self.index_built) self.buildStaticIndex() catch |e| {
                std.log.warn("static route index build failed (linear fallback in use): {t}", .{e});
            };

            // Fast path: try the static `"METHOD /path"` index for O(1) lookup
            // (no parameter capture needed — the route has no `:param`/`*rest`).
            var matched: ?*const Route = null;
            var matched_params: ctx_mod.Params = .{};
            const norm_path = normPath(request.path);
            var key_buf: [256]u8 = undefined;
            if (formatStaticKey(&key_buf, request.method, norm_path)) |key| {
                if (self.static_index.get(key)) |idx| {
                    matched = &self.routes.items[idx];
                }
            }

            // Slow path: linear scan over the (typically few) dynamic routes.
            if (matched == null) {
                for (self.routes.items) |*r| {
                    if (r.method != request.method) continue;
                    if (!routeIsDynamic(r.segments)) continue;
                    if (matchSegments(r.segments, request.path, &name_buf, &value_buf)) |params| {
                        matched = r;
                        matched_params = params;
                        break;
                    }
                }
            }

            var ctx: Ctx = .{
                .req = .{
                    .inner = request,
                    .params_ref = undefined,
                    .arena = arena,
                },
                .res = response,
                .arena = arena,
                .params = matched_params,
                .app_state = &self.state_value,
                .stream_ptr = stream_ptr,
                .io_ptr = io_ptr,
                .app_ref = @ptrCast(self),
            };
            ctx.req.params_ref = &ctx.params;

            const term: Handler(State) = if (matched) |r|
                r.handler
            else if (self.not_found_handler) |nf|
                nf
            else
                defaultNotFound;

            const chain = Next(State){
                .chain = self.middlewares.items,
                .terminal = term,
                .index = 0,
            };
            chain.run(&ctx) catch |err| {
                if (self.err_handler) |eh| {
                    eh(err, &ctx) catch |inner| {
                        std.log.err("error handler itself failed: {t} (original: {t})", .{ inner, err });
                    };
                } else {
                    std.log.warn("unhandled handler error on {s} {s}: {t}", .{
                        @tagName(request.method), request.path, err,
                    });
                    if (response.body.items.len == 0 and response.status_code == 200) {
                        response.setStatus(500);
                        response.json(.{ .error_kind = "internal", .err = @errorName(err) }) catch |jerr| {
                            std.log.err("failed to serialize error response: {t}", .{jerr});
                        };
                    }
                }
            };
        }

        fn defaultNotFound(c: *Ctx) anyerror!void {
            try c.notFound();
        }

        /// Index every fully-static route under `"METHOD /path"`. Called once
        /// before the first dispatch; subsequent registrations after serve()
        /// has started won't appear (callers should register up-front).
        fn buildStaticIndex(self: *Self) !void {
            for (self.routes.items, 0..) |*r, idx| {
                if (routeIsDynamic(r.segments)) continue;
                const key = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ @tagName(r.method), r.path });
                try self.static_index.put(key, idx);
            }
            self.index_built = true;
        }

        /// Start serving HTTP. On native this binds a TCP listener; on Workers
        /// this registers a dispatch callback with the WASM runtime and returns
        /// (the JS host will drive every subsequent request).
        pub fn serve(self: *Self, opts: ServeOptions) !void {
            const serve_mod = @import("serve.zig");
            return serve_mod.serve(State, self, opts);
        }
    };
}

fn concatPath(gpa: std.mem.Allocator, base: []const u8, sub: []const u8) ![]u8 {
    // Normalize: ensure exactly one '/' between base and sub.
    var b = base;
    var s = sub;
    while (b.len > 0 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    while (s.len > 0 and s[0] == '/') s = s[1..];
    if (b.len == 0) {
        const out = try gpa.alloc(u8, s.len + 1);
        out[0] = '/';
        @memcpy(out[1..], s);
        return out;
    }
    const out = try gpa.alloc(u8, b.len + 1 + s.len);
    @memcpy(out[0..b.len], b);
    out[b.len] = '/';
    @memcpy(out[b.len + 1 ..], s);
    return out;
}

/// True if any segment is `:param` or `*rest`.
fn routeIsDynamic(segs: []const Segment) bool {
    for (segs) |s| if (s.kind != .static) return true;
    return false;
}

/// Normalise an incoming request path by stripping a trailing `/` (so the
/// indexed key matches both `/users` and `/users/` to the same route).
fn normPath(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

/// Format `"METHOD path"` into the caller-provided buffer. Returns null if
/// the buffer is too small (caller falls back to the linear scan).
fn formatStaticKey(buf: []u8, method: Method, path: []const u8) ?[]u8 {
    const method_name = @tagName(method);
    const need = method_name.len + 1 + path.len;
    if (need > buf.len) return null;
    @memcpy(buf[0..method_name.len], method_name);
    buf[method_name.len] = ' ';
    @memcpy(buf[method_name.len + 1 ..][0..path.len], path);
    return buf[0..need];
}

test "concatPath builds canonical paths" {
    const t = std.testing;
    const a = try concatPath(t.allocator, "", "users");
    defer t.allocator.free(a);
    try t.expectEqualStrings("/users", a);
    const b = try concatPath(t.allocator, "/api", "/v1/posts");
    defer t.allocator.free(b);
    try t.expectEqualStrings("/api/v1/posts", b);
    const c = try concatPath(t.allocator, "/api/", "/v1/");
    defer t.allocator.free(c);
    try t.expectEqualStrings("/api/v1/", c);
}

test "parseSegments and matchSegments round-trip" {
    const t = std.testing;
    const segs = try parseSegments(t.allocator, "/api/users/:id");
    defer t.allocator.free(segs);
    var n: [4][]const u8 = undefined;
    var v: [4][]const u8 = undefined;
    const m = matchSegments(segs, "/api/users/42", &n, &v);
    try t.expect(m != null);
    try t.expectEqualStrings("id", m.?.names[0]);
    try t.expectEqualStrings("42", m.?.values[0]);
}
