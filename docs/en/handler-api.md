# Handler API Reference

Handlers have one signature:

```zig
fn handler(c: *am.Context(State)) !void
```

Unless a section says otherwise, returned slices and parsed values live in the
request arena and must not be retained after the handler returns. Operations
return Zig error unions; application errors can be handled with `app.onError`
or `am.mw.recover`. Native and Workers share the handler signature, but APIs
that require sockets or a filesystem are marked explicitly.

## Quick index

- [App Builder](#app-builder)
- [Context](#context)
- [Errors](#errors)
- [How to use State](#how-to-use-state)
- [Built-in middleware](#built-in-middleware)
- [Reference map](#reference-map)

## Reference map

| Area | Primary signature / entry point | Return, errors, lifetime, and backend |
|---|---|---|
| App | `am.App(State).init(allocator, state)` | Returns an owned app. Route registration can fail allocation; call `deinit()`. Native and Workers share the route table. |
| Context | `*am.Context(State)` | Borrowed for one request. `c.state()` is application-owned; `c.arena` values are request-owned. |
| Request | `c.req.param`, `paramAs`, `query`, `queries`, `json(T)`, `body`, `header` | Missing/parse/allocation errors use error unions where shown. Returned slices and decoded bodies are request-scoped. |
| Response | `c.json(value, status)`, `text`, `html`, `redirect`, `header`, `status` | Writes the current response and can fail serialization/allocation. Do not write another body after a streaming response commits. |
| Database | `c.db()`, then `Db.prepare`/`exec` and `Stmt.bind`/`step`/`column*` | `c.db()` enables request instrumentation. Statements own backend resources until `deinit()`. SQLite, D1, and Turso share the facade. |
| Model/repository | `am.model.repo(Model)` and `Model.__schema` | Comptime-generated CRUD; read results and text fields use the supplied arena. Database and validation errors are propagated. |
| HTTP client | `c.fetch(am.http_client.Request)` or `am.http_client.send(allocator, request)` | Returns a response/error; response slices use the supplied allocator (`c.arena` for `c.fetch`). `c.fetch` records timing and is available on native and Workers. Full URLs are not metric labels. |
| Authentication | `am.mw.bearerAuth`, `am.mw.jwt`, `am.auth.jwt`, `am.auth.password` | Middleware returns 401 on failed authentication. JWT middleware accepts HS256 only and validates `exp`/`nbf` against an injectable wall clock. |
| WebSocket | `app.ws(path, handler)` and `am.ws.upgrade(...)` | Native sockets are handled by Zig. Workers use the JavaScript/Durable Object integration described in the WebSocket guide. |
| SSE/streaming | `am.sse.open(c)` and `c.startStream(options)` | Native only. The writer is request-scoped and commits headers; write/flush operations can return I/O errors. |

See [Database backends](db-backends.md), [WebSocket](websocket.md), and
[Observability](observability.md) for backend-specific behavior.

## App Builder

```zig
var app = am.App(State).init(alloc, initial_state);
defer app.deinit();

// HTTP methods
_ = try app.get(path, handler);
_ = try app.post(path, handler);
_ = try app.put(path, handler);
_ = try app.delete(path, handler);
_ = try app.patch(path, handler);
_ = try app.options(path, handler);
_ = try app.head(path, handler);

// Match all HTTP methods
_ = try app.all(path, handler);

// WebSocket (internally GET + RouteKind.ws)
_ = try app.ws(path, handler);

// Middleware
_ = try app.useAll(am.mw.logger(State));            // Apply to every route
_ = try app.use("/api/*", am.mw.bearerAuth(State, .{ .token = "x" }));  // Path match

// Groups are lightweight values backed by the parent App
var api = try app.basePath("/api/v1");
_ = try api.get("/users", listUsers);

// Error / Not Found handlers
try app.notFound(myNotFound);
try app.onError(myErrorHandler);

// Start (automatically selects the backend)
try app.serve(.{ .port = 8080 });
```

`prepare()` builds the static index and freezes the route table. The first
dispatch and `serve()` call it automatically. Later registration returns
`error.RoutesFrozen`. Registration also rejects duplicate/equivalent routes,
ambiguous parameter routes, repeated capture names, non-terminal wildcards,
and more than 16 captures. A `Group` borrows its parent; only the parent is
deinitialized.

Without an explicit `HEAD` route, `HEAD` uses `GET` but sends no body. A known
path with the wrong method returns `405` and a deduplicated `Allow` header;
`GET` implies `HEAD`.

`c.req.ip()` uses only the direct peer by default. Forwarding headers require
both `trust_proxy_headers = true` and a `trusted_proxy_fn` that authorizes the
direct peer.

Routes, middleware, groups, and hooks freeze together. `use`, `useAll`,
`basePath`, `notFound`, and `onError` return `error.RoutesFrozen` after
`prepare()`.

## Context

```zig
fn handler(c: *am.Context(State)) !void {
    // === Request ===
    const m = c.req.method();                  // "GET"
    const p = c.req.path();                    // "/users/42"
    const auth = c.req.header("authorization");// ?[]const u8

    const id = try c.req.param("id");          // []const u8 (error.MissingParam, not 404)
    const num = try c.req.paramAs(u64, "id");  // Type conversion

    const limit = c.req.query("limit") orelse "10";
    const all_q = try c.req.queries("tag");    // Collect repeated query values

    const Body = struct { name: []const u8 };
    const body = try c.req.json(Body);         // Parse in the arena
    const raw = c.req.body();                  // []const u8

    // === Response ===
    c.status(201);
    try c.header("x-trace", "abc");
    try c.json(.{ .ok = true }, 200);
    try c.text("hello");
    try c.html("<h1>hi</h1>");
    try c.redirect("/login", 302);
    try c.notFound();

    // === State ===
    const s: *State = c.state();               // Access the generic State
    _ = s.db;

    // === Per-request arena ===
    const buf = try c.arena.alloc(u8, 64);
    _ = buf;
}
```

## Errors

If the handler returns `error.X`, you can catch it with `onError`. With `recover` middleware `useAll`, unhandled errors are automatically mapped to 500:

```zig
_ = try app.useAll(am.mw.recover(State));

fn handler(c: *am.Context(State)) !void {
    return error.SomethingBroke;
}
// → 500 + {"error_kind":"internal","message":"internal server error"}
```

## How to use State

```zig
const State = struct {
    db: am.db.Db,
    users_seen: std.atomic.Value(u64) = .init(0),
};

fn createUser(c: *am.Context(State)) !void {
    var stmt = try c.state().db.prepare("INSERT INTO users(name) VALUES(?)");
    defer stmt.deinit();
    try stmt.bindAll(.{"alice"});
    _ = try stmt.step();
    _ = c.state().users_seen.fetchAdd(1, .seq_cst);
    try c.json(.{ .created = true }, 201);
}
```

## Passing data from middleware

```zig
// JWT mw が stash した claims を読む
fn protected(c: *am.Context(State)) !void {
    const claims = am.mw.currentJwtClaims(State, c) orelse {
        return c.json(.{ .error_kind = "unauthorized" }, 401);
    };
    try c.json(.{ .me = claims.sub }, 200);
}
```

Custom values ​​can also be passed in `c.user_data` (opaque pointer).

## Built-in middleware

`app.useAll(middleware)` applies middleware globally; `app.use(pattern,
middleware)` applies it to matching paths. Options are `comptime`, so their
strings must remain valid for the application's lifetime.

| Signature | Important defaults and notes |
|---|---|
| `recover(State)` | Maps an unhandled handler error to a generic 500 response; it does not expose the error text. |
| `logger(State)` | Simple method/path/status development log. Use `accessLog` for structured production output. |
| `requestId(State)` | Accepts a printable `X-Request-ID` up to 64 bytes or generates UUIDv4; available through `c.requestId()`. |
| `accessLog(State, format)` | `format` is `.json` or `.combined`. `accessLogWithOptions` defaults to JSON and excludes the raw path. |
| `metrics(State, *MetricsCounters)` | Records request metrics with the `.web` latency profile. `metricsWithConfig` also accepts `.fast`; expose with `metricsHandler`. |
| `serverTiming(State, options)` | Disabled by default; `include_named_spans = true`. Opt in only when exposing component names is acceptable. |
| `cors(State, options)` | Origin `*`; common methods and `content-type,authorization`; credentials off. Do not combine wildcard origin with credentials for credentialed browser traffic. |
| `bearerAuth(State, options)` | Requires a fixed `token`; realm defaults to `Restricted`. Compare and store secrets outside source code. |
| `jwt(State, options)` | Requires an HS256 `secret`; claims are placed in `user_data` by default. `exp` is required and `exp`/`nbf` are checked by default. `require_exp`, `leeway_seconds`, `reject_future_iat`, and `now_fn` configure policy. |
| `session(State, options)` | Requires an HMAC secret of at least 32 bytes. The signed cookie contains a server-enforced expiry; defaults are one week, `HttpOnly`, `Secure`, `SameSite=Lax`. Set `cookie_secure=false` explicitly for plain-HTTP local development. The default store is process-local memory. Call `Session.rotate(c)` after login or a privilege change. |
| `csrf(State, options)` | Double-submit cookie; safe methods are GET/HEAD/OPTIONS. The cookie is JS-readable by design and `Secure` by default. |
| `rateLimit(State, options)` | Requires `key_fn`; defaults to 60 requests per 60 seconds and emits headers. State is process/isolate local, not a distributed quota. |
| `secureHeaders(State, options)` | API-oriented HSTS/CSP/frame/MIME/referrer/permissions defaults; customize CSP for HTML applications. |
| `compress(State, options)` | Minimum 1024 bytes; prefers gzip then deflate. Buffered native responses only; no-op on Workers and streaming responses. |
| `etag(State, options)` | Strong SHA-256 ETag for buffered 2xx bodies of at least 32 bytes; can rewrite to 304. |
| `serveStatic(State, options)` | Requires `root`; prefix `/`, index `index.html`. Native only; use Workers assets on Cloudflare. |

For production observability, register the outer middleware in this order:

```zig
_ = try app.useAll(am.mw.requestId(State));
_ = try app.useAll(am.mw.accessLogWithOptions(State, .{}));
_ = try app.useAll(am.mw.metrics(State, &counters));
_ = try app.useAll(am.mw.serverTiming(State, .{ .enabled = false }));
```

Each middleware wraps those registered after it. Place authentication,
session, CSRF, and rate limiting before protected handlers. See
[Observability](observability.md) for metric names, spans, and privacy rules.

## Input parsing + validation (`c.input`)

```zig
pub const CreateUser = struct {
    name: []const u8,
    email: []const u8,

    pub const __schema = .{
        .validates = .{
            .name = .{ am.model.rule.required, am.model.rule.min_len(1), am.model.rule.max_len(80) },
            .email = .{ am.model.rule.required, am.model.rule.format(.email) },
        },
    };
};

fn create(c: *am.Context(State)) !void {
    const input = (try c.input(CreateUser)) orelse return;
    // ... `input` は検証済み
}
```

Behavior of `c.input(T)`:

- Write truly malformed JSON → 400 and null
- Missing field/constraint violation → write 422 (`{error_kind, errors:[{field,rule,message}]}`) and null
- Success → return T

Every non-optional field without a default is required structurally, even if
it is absent from `__schema.validates`. Use an optional field or a default for
PATCH-style input.

Internally, there are two steps: permissive parse to "projection with all fields optional", run validate, and missing fields are converted to 422 using the `required` rule. Even if I send `{}`, I get a field-level error of 422 instead of 400.

### PATCH optional field

```zig
pub const UpdateUser = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,

    pub const __schema = .{ .validates = .{
        .name = .{ am.model.rule.min_len(1), am.model.rule.max_len(80) },
        .email = .{ am.model.rule.format(.email) },
    } };
};
```

`min_len`/`max_len`/`format`/`range`/`custom_text` will **skip the rule** if optional is null — that is, ``fields not sent'' will not be validated in PATCH. Only `required` treats optional null as a failure (expression of "optional but required").

## Streaming and SSE

```zig
fn longResponse(c: *am.Context(State)) !void {
    const w = try c.startStream(.{ .content_type = "text/plain; charset=utf-8" });
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try w.print("line {d}\n", .{i});
        try w.flush();   // 各 flush が 1 chunk として送出される
    }
}

fn liveUpdates(c: *am.Context(State)) !void {
    var sse = try am.sse.open(c);
    try sse.send(.{ .event = "tick", .data = "{\"now\":42}" });
    try sse.heartbeat();    // proxy アイドル切断対策
}
```

The streaming response is fixed at `keep_alive=false`, and `transfer-encoding: chunked` is automatically assigned. Even if the handler returns an error, the server side terminates normally with 0-chunk + flush, so the connection will not be suspended due to partial body.

## Content negotiation

```zig
fn dual(c: *am.Context(State)) !void {
    const mt = c.negotiate(&.{ "application/json", "text/html" }) orelse {
        try c.json(.{ .error_kind = "not_acceptable" }, 406);
        return;
    };
    if (std.mem.eql(u8, mt, "text/html")) try c.html(page) else try c.json(payload, 200);
}
```

`c.negotiate(...)` evaluates q-value + specificity according to RFC 9110 §12.5 and returns the best media type from the server-side candidate list. If there is no match, the caller should return 406.

## Get framework App pointer (`c.app()`)

Handlers that dynamically issue OpenAPI specifications or TypeScript clients need to walk the route table at runtime, and request `*am.App(State)` at that time. You can get it with `c.app()`:

```zig
fn openapiSpec(c: *am.Context(State)) !void {
    const fw = c.app().?;
    const spec = try am.openapi.generate(@TypeOf(fw.*), fw, c.arena, .{ .title = "...", .version = "..." });
    try c.res.header("content-type", "application/json");
    try c.res.writeAll(spec);
}
```

Generation includes every registered HTTP route. Ordinary helpers produce an
untyped operation; `endpoint()` adds reflected request, response, and query
metadata. Complete route registration before serving a generated artifact.
`Spec` can also declare `operation_id`, `deprecated`, content types, success
status, additional response statuses, and security requirements; document-level
security schemes belong in `Info.security_schemes`.

It will be null for routes that do not go through `app.dispatch`, such as unit test.

## Lifecycle Management (`app.own`)

If you want State to have a long-lived heap resource (SSE channel, job queue, external service client, etc.), link the lifespan to the App using `app.own(ptr)`. `app.deinit()` calls `ptr.deinit()` then `gpa.destroy(ptr)` in reverse order of registration:

```zig
const events = try alloc.create(EventChannel);
events.* = EventChannel.init(alloc);
try app.own(events);
app.state().events = events;
```

`Child.deinit(*Self)` or `Child.deinit(*Self, Allocator)` is auto-detected.

## Synchronization Primitive (`am.sync`)

Since `std.Thread.Mutex` / `Condition` have been dropped from Zig 0.16 std, Akamata provides a thinly wrapped replacement for libc pthreads:

```zig
const m = am.sync.Mutex.init();  // = am.Mutex.init()
defer m.deinit();
m.lock(); defer m.unlock();
```

The same goes for `am.sync.Condition`. `am.Mutex` / `am.Condition` are aliases of the same type. Please protect the shared State field with these or `std.atomic.Value(T)`.

## Test client

You can test your app with `am.testing.Client` without TCP / threads / port conflicts:

```zig
var client = am.testing.Client(@TypeOf(app)).init(alloc, &app);
defer client.deinit();

var resp = try client.post("/tasks").bearer(token).json(.{ .title = "x" }).send();
defer resp.deinit();
try std.testing.expectEqual(@as(u16, 201), resp.status);

// 動的 path は format ヘルパで
var del = try client.deletef("/tasks/{d}", .{id}).send();
defer del.deinit();
```

Typed parse with `resp.json(T)`, get header with `resp.header(name)`. See `examples/tasks/src/integration_test.zig` for details.
