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
const sync = @import("sync.zig");

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
        /// Per-registration state. `setup` is called by `use`/`useAll`, so
        /// identical middleware factories used by different Apps never share
        /// mutable storage.
        data: ?*anyopaque = null,
        setup: ?*const fn (gpa: std.mem.Allocator) anyerror!*anyopaque = null,
        cleanup: ?*const fn (gpa: std.mem.Allocator, data: *anyopaque) void = null,
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
                    const previous_data = c.middleware_data;
                    defer c.middleware_data = previous_data;
                    c.middleware_data = entry.mw.data;
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
    /// Reserved experimental reactor. `serve()` currently fails closed with
    /// `error.ExperimentalRuntimeDisabled` because it has not reached the
    /// threaded runtime's security and backpressure guarantees.
    reactor,
};

pub const ServeOptions = struct {
    address: ?[]const u8 = null,
    port: u16 = 8080,
    accept_thread_count: usize = 4,
    /// HTTP parsing limits used by the Workers/WASM bridge. Increase
    /// `max_body_bytes` for endpoints that intentionally accept larger
    /// request bodies, such as image uploads.
    parse_limits: parser.Limits = .{},
    /// HTTP runtime selection. `.threaded` is the current production
    /// model; `.reactor` is the new kqueue-based prototype (BSD-family
    /// kernels only). See `docs/en/perf-reactor-design.md`.
    runtime: Runtime = .threaded,
    /// Number of worker threads when `runtime == .reactor`. `null` =
    /// `std.Thread.getCpuCount()` (default). Has no effect on the
    /// threaded runtime, which uses `accept_thread_count` instead.
    worker_count: ?usize = null,
    /// Deprecated compatibility alias. Phase-specific deadlines below are
    /// enforced by the threaded server without SO_RCVTIMEO.
    read_timeout_ms: u32 = 30_000,
    write_timeout_ms: u32 = 30_000,
    header_read_timeout_ms: u32 = 10_000,
    body_read_timeout_ms: u32 = 30_000,
    keep_alive_idle_timeout_ms: u32 = 5_000,
    total_request_timeout_ms: u32 = 60_000,
    max_requests_per_connection: u32 = 100,
    /// Bounds detached connection workers and their request buffers.
    max_connections: usize = 1024,
    /// Honor forwarding headers only when the immediate peer is a trusted
    /// reverse proxy. Off by default to prevent client-controlled IP spoofing.
    trust_proxy_headers: bool = false,
    /// Required policy callback when forwarding headers are enabled. It sees
    /// the direct peer (`null` on targets without socket metadata) and must
    /// explicitly authorize that hop.
    trusted_proxy_fn: ?*const fn (peer_ip: ?[]const u8) bool = null,
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
        group_prefixes: std.ArrayList([]u8) = .empty,
        not_found_handler: ?H = null,
        err_handler: ?EH = null,
        /// Optimisation: routes with only static segments are stored in a
        /// `"METHOD path"` -> route index map for O(1) lookup. Routes that
        /// contain `:param` or `*rest` fall back to linear scan in `routes`.
        /// Built lazily on the first request to allow registration to keep
        /// happening up to `serve()`.
        static_index: std.StringHashMap(usize) = undefined,
        index_built: bool = false,
        routes_frozen: bool = false,
        index_mu: sync.Mutex,
        trust_proxy_headers: bool = false,
        trusted_proxy_fn: ?*const fn (peer_ip: ?[]const u8) bool = null,
        /// Set by `requestShutdown()`. Read by the accept loop on every
        /// iteration; once true, the listener is closed and the loop returns.
        shutdown_flag: std.atomic.Value(bool) = .init(false),
        /// Listener socket fd, set by serve() while the loop is running.
        /// Used by `requestShutdown()` to close the fd from another thread
        /// (which makes `accept()` return `error.SocketNotListening`).
        listener_fd: std.atomic.Value(i32) = .init(-1),
        startup_hook: ?*const fn (*Self) anyerror!void = null,
        shutdown_hook: ?*const fn (*Self) anyerror!void = null,
        lifecycle_started: bool = false,

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
            /// are included as untyped operations in the generated spec.
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
            middleware_names: []const []const u8,
        };

        /// Snapshot of every registered route. The returned slice is
        /// borrowed from the App and is invalidated by any subsequent
        /// `app.get/post/.../endpoint` call; allocate first if you need
        /// to hold onto it across registrations.
        pub fn routeViews(self: *const Self, arena: std.mem.Allocator) ![]const RouteView {
            var out = try arena.alloc(RouteView, self.routes.items.len);
            for (self.routes.items, 0..) |r, i| {
                var names: std.ArrayList([]const u8) = .empty;
                for (self.middlewares.items) |entry| {
                    if (entry.pattern.len == 0 or patternMatches(entry.pattern, r.path))
                        try names.append(arena, entry.mw.name);
                }
                out[i] = .{
                    .method = r.method,
                    .kind = r.kind,
                    .path = r.path,
                    .meta = r.meta,
                    .middleware_names = try names.toOwnedSlice(arena),
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
                .index_mu = sync.Mutex.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.stopLifecycle() catch |err| std.log.err("application shutdown hook failed: {s}", .{@errorName(err)});
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
            self.index_mu.deinit();
            for (self.routes.items) |r| {
                self.gpa.free(r.path);
                self.gpa.free(r.segments);
            }
            self.routes.deinit(self.gpa);
            for (self.middlewares.items) |entry| {
                if (entry.mw.cleanup) |cleanup| if (entry.mw.data) |data| cleanup(self.gpa, data);
                if (entry.pattern.len > 0) self.gpa.free(entry.pattern);
            }
            self.middlewares.deinit(self.gpa);
            for (self.group_prefixes.items) |prefix| self.gpa.free(prefix);
            self.group_prefixes.deinit(self.gpa);
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
                            else => @compileError("app.own deinit must accept (*Self) or (*Self, Allocator)"),
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

        pub const Lifecycle = struct {
            startup: ?*const fn (*Self) anyerror!void = null,
            shutdown: ?*const fn (*Self) anyerror!void = null,
        };

        /// Register application-wide resource setup and teardown. Startup is
        /// invoked once before serving; shutdown is invoked once by deinit,
        /// including after a requested graceful stop.
        pub fn lifecycle(self: *Self, hooks: Lifecycle) !void {
            if (self.lifecycle_started) return error.LifecycleAlreadyStarted;
            self.startup_hook = hooks.startup;
            self.shutdown_hook = hooks.shutdown;
        }

        pub fn startLifecycle(self: *Self) !void {
            if (self.lifecycle_started) return;
            if (self.startup_hook) |hook| try hook(self);
            self.lifecycle_started = true;
        }

        pub fn stopLifecycle(self: *Self) !void {
            if (!self.lifecycle_started) return;
            self.lifecycle_started = false;
            if (self.shutdown_hook) |hook| try hook(self);
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
        pub fn head(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.HEAD, .http, path, h);
        }
        pub fn ws(self: *Self, path: []const u8, h: H) !*Self {
            return self.add(.GET, .ws, path, h);
        }
        /// Register the same handler for every HTTP method.
        pub fn all(self: *Self, path: []const u8, h: H) !*Self {
            inline for ([_]Method{ .GET, .HEAD, .POST, .PUT, .DELETE, .PATCH, .OPTIONS }) |m| {
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
            if (self.routes_frozen) return error.RoutesFrozen;
            const full_path = try concatPath(self.gpa, self.base_prefix, path_in);
            errdefer self.gpa.free(full_path);
            for (self.routes.items) |existing| {
                if (existing.method == method and pathsEquivalent(existing.path, full_path))
                    return error.DuplicateRoute;
            }
            const segs = try parseSegments(self.gpa, full_path);
            errdefer self.gpa.free(segs);
            for (self.routes.items) |existing| {
                if (existing.method == method and routeShapesConflict(existing.segments, segs))
                    return error.AmbiguousRoute;
            }
            var capture_count: usize = 0;
            for (segs, 0..) |seg, i| {
                if (seg.kind != .static) {
                    capture_count += 1;
                    for (segs[0..i]) |prior| {
                        if (prior.kind != .static and std.mem.eql(u8, prior.text, seg.text))
                            return error.DuplicatePathParameter;
                    }
                }
                if (seg.kind == .wildcard and i + 1 != segs.len) return error.WildcardMustBeLast;
            }
            if (capture_count > 16) return error.TooManyPathParameters;
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
            if (self.routes_frozen) return error.RoutesFrozen;
            const full = try concatPath(self.gpa, self.base_prefix, pattern);
            errdefer self.gpa.free(full);
            const instance = try instantiateMiddleware(self.gpa, mw);
            errdefer cleanupMiddleware(self.gpa, instance);
            try self.middlewares.append(self.gpa, .{ .mw = instance, .pattern = full });
            return self;
        }

        /// Global middleware (runs before every handler).
        pub fn useAll(self: *Self, mw: Mw) !*Self {
            if (self.routes_frozen) return error.RoutesFrozen;
            const instance = try instantiateMiddleware(self.gpa, mw);
            errdefer cleanupMiddleware(self.gpa, instance);
            try self.middlewares.append(self.gpa, .{ .mw = instance, .pattern = "" });
            return self;
        }

        // ===== Grouping =====

        /// Returns a borrowed view of `self` that prepends `prefix` to any
        /// subsequently registered routes/middlewares. The view aliases the
        /// underlying storage, so groups share routes and state.
        pub const Group = struct {
            app: *Self,
            prefix: []const u8,

            pub fn get(g: *Group, path: []const u8, h: H) !*Group {
                return g.add(.GET, .http, path, h);
            }
            pub fn post(g: *Group, path: []const u8, h: H) !*Group {
                return g.add(.POST, .http, path, h);
            }
            pub fn put(g: *Group, path: []const u8, h: H) !*Group {
                return g.add(.PUT, .http, path, h);
            }
            pub fn delete(g: *Group, path: []const u8, h: H) !*Group {
                return g.add(.DELETE, .http, path, h);
            }
            pub fn patch(g: *Group, path: []const u8, h: H) !*Group {
                return g.add(.PATCH, .http, path, h);
            }
            pub fn options(g: *Group, path: []const u8, h: H) !*Group {
                return g.add(.OPTIONS, .http, path, h);
            }
            pub fn head(g: *Group, path: []const u8, h: H) !*Group {
                return g.add(.HEAD, .http, path, h);
            }
            pub fn ws(g: *Group, path: []const u8, h: H) !*Group {
                return g.add(.GET, .ws, path, h);
            }
            pub fn use(g: *Group, pattern: []const u8, mw: Mw) !*Group {
                if (g.app.routes_frozen) return error.RoutesFrozen;
                const full = try concatPath(g.app.gpa, g.prefix, pattern);
                errdefer g.app.gpa.free(full);
                const instance = try instantiateMiddleware(g.app.gpa, mw);
                errdefer cleanupMiddleware(g.app.gpa, instance);
                try g.app.middlewares.append(g.app.gpa, .{ .mw = instance, .pattern = full });
                return g;
            }
            pub fn basePath(g: *Group, prefix: []const u8) !Group {
                return g.app.makeGroup(g.prefix, prefix);
            }
            fn add(g: *Group, method: Method, kind: RouteKind, path: []const u8, h: H) !*Group {
                const full = try concatPath(g.app.gpa, g.prefix, path);
                defer g.app.gpa.free(full);
                _ = try g.app.add(method, kind, full, h);
                return g;
            }
        };

        pub fn basePath(self: *Self, prefix: []const u8) !Group {
            return self.makeGroup(self.base_prefix, prefix);
        }

        fn makeGroup(self: *Self, base: []const u8, prefix: []const u8) !Group {
            if (self.routes_frozen) return error.RoutesFrozen;
            const full = try concatPath(self.gpa, base, prefix);
            errdefer self.gpa.free(full);
            try self.group_prefixes.append(self.gpa, full);
            return .{ .app = self, .prefix = full };
        }

        // ===== Hooks =====

        pub fn notFound(self: *Self, h: H) !void {
            if (self.routes_frozen) return error.RoutesFrozen;
            self.not_found_handler = h;
        }

        pub fn onError(self: *Self, h: EH) !void {
            if (self.routes_frozen) return error.RoutesFrozen;
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
            return self.dispatchWithPeer(arena, request, response, stream_ptr, io_ptr, null);
        }

        pub fn dispatchWithPeer(
            self: *Self,
            arena: std.mem.Allocator,
            request: *req_mod.Request,
            response: *res_mod.Response,
            stream_ptr: ?*anyopaque,
            io_ptr: ?*anyopaque,
            peer_ip: ?[]const u8,
        ) !void {
            var name_buf: [16][]const u8 = undefined;
            var value_buf: [16][]const u8 = undefined;

            // Build the static-route index lazily on first request. If the
            // build fails (OOM), the linear fallback below still works, so
            // we log a warning rather than failing the request.
            if (!self.index_built) self.prepare() catch |e| {
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
            // RFC semantics: HEAD uses an explicit HEAD route when present,
            // otherwise it falls back to the matching GET handler.
            if (matched == null and request.method == .HEAD) {
                if (formatStaticKey(&key_buf, .GET, norm_path)) |key| {
                    if (self.static_index.get(key)) |idx| matched = &self.routes.items[idx];
                }
            }

            // Slow path: linear scan over the (typically few) dynamic routes.
            if (matched == null) {
                for (self.routes.items) |*r| {
                    if (r.method != request.method and !(request.method == .HEAD and r.method == .GET)) continue;
                    if (matchSegments(r.segments, request.path, &name_buf, &value_buf)) |params| {
                        matched = r;
                        matched_params = params;
                        break;
                    }
                }
            }

            if (matched) |route| if (route.meta) |meta| if (meta.limits.request_bytes) |limit| {
                if (request.body.len > limit) {
                    response.setStatus(413);
                    try response.json(.{ .error_kind = "request_too_large", .limit = limit });
                    return;
                }
            };

            var ctx: Ctx = .{
                .req = .{
                    .inner = request,
                    .params_ref = undefined,
                    .arena = arena,
                    .trust_proxy_headers = self.trust_proxy_headers and
                        (if (self.trusted_proxy_fn) |trust| trust(peer_ip) else false),
                    .peer_ip = peer_ip,
                },
                .res = response,
                .arena = arena,
                .params = matched_params,
                .app_state = &self.state_value,
                .stream_ptr = stream_ptr,
                .io_ptr = io_ptr,
                .app_ref = @ptrCast(self),
            };
            response.suppress_body = request.method == .HEAD;
            ctx.trace.route_pattern = if (matched) |r| r.path else null;
            ctx.trace.begin();
            defer ctx.trace.finish();
            ctx.req.params_ref = &ctx.params;

            var method_not_allowed = false;
            if (matched == null) {
                var allowed = [_]bool{false} ** @typeInfo(Method).@"enum".fields.len;
                for (self.routes.items) |r| {
                    var scratch_names: [16][]const u8 = undefined;
                    var scratch_values: [16][]const u8 = undefined;
                    if (matchSegments(r.segments, request.path, &scratch_names, &scratch_values) == null) continue;
                    allowed[@intFromEnum(r.method)] = true;
                    if (r.method == .GET) allowed[@intFromEnum(Method.HEAD)] = true;
                }
                var allow: std.ArrayList(u8) = .empty;
                inline for (@typeInfo(Method).@"enum".fields) |field| {
                    if (allowed[field.value]) {
                        if (allow.items.len > 0) try allow.appendSlice(arena, ", ");
                        try allow.appendSlice(arena, field.name);
                    }
                }
                if (allow.items.len != 0) {
                    method_not_allowed = true;
                    response.setStatus(405);
                    try response.header("allow", allow.items);
                    try response.json(.{ .error_kind = "method_not_allowed" });
                }
            }

            const term: Handler(State) = if (matched) |r|
                r.handler
            else if (method_not_allowed)
                noOp
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
                        response.json(.{ .error_kind = "internal", .message = "internal server error" }) catch |jerr| {
                            std.log.err("failed to serialize error response: {t}", .{jerr});
                        };
                    }
                }
            };
            if (matched) |route| if (route.meta) |meta| if (meta.limits.response_bytes) |limit| {
                if (response.streaming == null and response.body.items.len > limit) {
                    response.body.clearRetainingCapacity();
                    response.setStatus(500);
                    try response.json(.{ .error_kind = "response_budget_exceeded", .limit = limit });
                }
            };
        }

        fn defaultNotFound(c: *Ctx) anyerror!void {
            try c.notFound();
        }

        fn noOp(_: *Ctx) anyerror!void {}

        /// Index every fully-static route under `"METHOD /path"`. Called once
        /// before the first dispatch; subsequent registrations after serve()
        /// has started won't appear (callers should register up-front).
        pub fn prepare(self: *Self) !void {
            self.index_mu.lock();
            defer self.index_mu.unlock();
            if (self.index_built) return;
            var next_index = std.StringHashMap(usize).init(self.gpa);
            errdefer {
                var failed_it = next_index.iterator();
                while (failed_it.next()) |entry| self.gpa.free(entry.key_ptr.*);
                next_index.deinit();
            }
            for (self.routes.items, 0..) |*r, idx| {
                if (routeIsDynamic(r.segments)) continue;
                const key = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ @tagName(r.method), normPath(r.path) });
                next_index.put(key, idx) catch |err| {
                    self.gpa.free(key);
                    return err;
                };
            }
            self.static_index.deinit();
            self.static_index = next_index;
            self.index_built = true;
            self.routes_frozen = true;
        }

        /// Start serving HTTP. On native this binds a TCP listener; on Workers
        /// this registers a dispatch callback with the WASM runtime and returns
        /// (the JS host will drive every subsequent request).
        pub fn serve(self: *Self, opts: ServeOptions) !void {
            const serve_mod = @import("serve.zig");
            try self.startLifecycle();
            return serve_mod.serve(State, self, opts);
        }
    };
}

fn instantiateMiddleware(gpa: std.mem.Allocator, mw: anytype) !@TypeOf(mw) {
    var out = mw;
    if (mw.setup) |setup| out.data = try setup(gpa);
    return out;
}

fn cleanupMiddleware(gpa: std.mem.Allocator, mw: anytype) void {
    if (mw.cleanup) |cleanup| if (mw.data) |data| cleanup(gpa, data);
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

fn routeShapesConflict(a: []const Segment, b: []const Segment) bool {
    const common = @min(a.len, b.len);
    for (a[0..common], b[0..common]) |left, right| {
        if (left.kind == .wildcard or right.kind == .wildcard) return true;
        if (left.kind == .static and right.kind == .static) {
            if (!std.mem.eql(u8, left.text, right.text)) return false;
        } else if (left.kind == .static or right.kind == .static) {
            return false;
        }
    }
    return a.len == b.len;
}

/// Normalise an incoming request path by stripping a trailing `/` (so the
/// indexed key matches both `/users` and `/users/` to the same route).
fn normPath(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

fn pathsEquivalent(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, normPath(a), normPath(b));
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

test "application lifecycle runs startup and shutdown once" {
    const State = struct { starts: *usize, stops: *usize };
    const TestApp = App(State);
    const hooks = struct {
        fn start(app: *TestApp) !void {
            app.state().starts.* += 1;
        }
        fn stop(app: *TestApp) !void {
            app.state().stops.* += 1;
        }
    };
    var starts: usize = 0;
    var stops: usize = 0;
    var app = TestApp.init(std.testing.allocator, .{ .starts = &starts, .stops = &stops });
    try app.lifecycle(.{ .startup = hooks.start, .shutdown = hooks.stop });
    try app.startLifecycle();
    try app.startLifecycle();
    try std.testing.expectEqual(@as(usize, 1), starts);
    app.deinit();
    try std.testing.expectEqual(@as(usize, 1), stops);
}
