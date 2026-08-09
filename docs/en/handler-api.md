# Handler API (new Hono style)

Handlers have one signature:

```zig
fn handler(c: *am.Context(State)) !void
```

## App Builder

```zig
var app = am.App(State).init(alloc, initial_state);
defer app.deinit();

// HTTP メソッド
_ = try app.get(path, handler);
_ = try app.post(path, handler);
_ = try app.put(path, handler);
_ = try app.delete(path, handler);
_ = try app.patch(path, handler);
_ = try app.options(path, handler);

// すべてのメソッドにマッチ
_ = try app.all(path, handler);

// WebSocket (内部的には GET + RouteKind.ws)
_ = try app.ws(path, handler);

// ミドルウェア
_ = try app.useAll(am.mw.logger(State));            // 全ルートに適用
_ = try app.use("/api/*", am.mw.bearerAuth(State, .{ .token = "x" }));  // パスマッチ

// グループ (basePath の戻り値は *App(State)、prefix が積まれる)
var api = try app.basePath("/api/v1");
_ = try api.get("/users", listUsers);

// エラー / Not Found ハンドラ
app.notFound(myNotFound);
app.onError(myErrorHandler);

// 起動 (backend で自動分岐)
try app.serve(.{ .port = 8080 });
```

## Context (equivalent to Hono's `c`)

```zig
fn handler(c: *am.Context(State)) !void {
    // === Request 側 ===
    const m = c.req.method();                  // "GET"
    const p = c.req.path();                    // "/users/42"
    const auth = c.req.header("authorization");// ?[]const u8

    const id = try c.req.param("id");          // []const u8 (404 ではなく error.MissingParam を投げる)
    const num = try c.req.paramAs(u64, "id");  // 型変換

    const limit = c.req.query("limit") orelse "10";
    const all_q = try c.req.queries("tag");    // 同名の複数 query を集約

    const Body = struct { name: []const u8 };
    const body = try c.req.json(Body);         // arena に parse
    const raw = c.req.body();                  // []const u8

    // === Response 側 ===
    c.status(201);
    try c.header("x-trace", "abc");
    try c.json(.{ .ok = true }, 200);
    try c.text("hello");
    try c.html("<h1>hi</h1>");
    try c.redirect("/login", 302);
    try c.notFound();

    // === State ===
    const s: *State = c.state();               // ジェネリック型の State にアクセス
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

| | Description |
|---|---|
| `am.mw.logger(State)` | Request log (method/path/status) |
| `am.mw.recover(State)` | error → 500 map |
| `am.mw.cors(State, opts)` | CORS header + OPTIONS preflight |
| `am.mw.bearerAuth(State, opts)` | Fixed Token Bearer |
| `am.mw.jwt(State, opts)` | JWT HS256 validation + claims injection |
| `am.mw.serveStatic(State, opts)` | Static files (native only) |
| `am.mw.requestId(State)` | Numbering `X-Request-ID` with UUIDv4 |
| `am.mw.rateLimit(State, opts)` | Fixed window rate-limit |
| `am.mw.session(State, opts)` | Signed Cookie + Replaceable Store |
| `am.mw.csrf(State, opts)` | double-submit cookie |
| `am.mw.metrics(State, opts)` | Prometheus + Latency Histogram |
| `am.mw.accessLog(State, opts)` | Structured JSON / Apache combined logs |
| `am.mw.secureHeaders(State, opts)` | Presets such as HSTS / CSP / X-Frame-Options |
| `am.mw.compress(State, opts)` | gzip/deflate (no-op on Workers) |
| `am.mw.etag(State, opts)` | SHA-256 ETag automatic grant + 304 rewrite |

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
