# Example: tasks — Best practice API

`examples/tasks/` is a task management REST API that combines Akamata's representative functions into one application. The code is heavily commented so that you can use it as a starting point when writing a new app, or as a reference for asking yourself, "How do I use this feature?"

This document provides an overview of the Example and explains why each feature is organized the way it is. Please refer to `docs/en/handler-api.md` for the Akamata main API reference.

## Functions handled by this sample

| Features | Implementation location | Related IMP |
|---|---|---|
| Model + automatic migration + validation | `c.input()` of `src/models.zig`, `src/handlers.zig` | — |
| OpenAPI 3.1 automatic generation | `app.endpoint(...)` of `src/setup.zig`, `openapiSpec` of `src/handlers.zig` | IMP-2 |
| Type-safe TypeScript client generation | `typescriptClient` of `src/handlers.zig` | IMP-10 |
| Streaming + SSE | `streamEvents` of `src/handlers.zig`, `EventChannel` of `src/app.zig` | IMP-1 |
| Persistent job queue | Queue construction for `src/setup.zig`, `notifyJob` for `src/handlers.zig` | IMP-5 |
| Middleware stack (logger / recover / requestId / cors / secureHeaders / compress / etag) | `useAll(...)` of `src/setup.zig` | IMP-3, IMP-4, IMP-9 |
| E2E test on `am.testing.Client` | `src/integration_test.zig` | IMP-6 |

The resource is `tasks` It is a simple CRUD with only one table, but all the above functions are working in **actual code**, so you can verify it as a test with `zig build tasks-test`.

## Directory structure

```
examples/tasks/
└── src/
    ├── app.zig              # State type + EventChannel (SSE pub/sub)
    ├── models.zig           # `Task` model + automatic migration manifest
    ├── handlers.zig         # Per-route handlers
    ├── setup.zig            # App build, middleware chain, and route registration
    ├── main.zig             # Native entry point
    └── integration_test.zig # Tests with am.testing.Client
```

## Build & Run

```sh
# サーバ起動 (default: SQLite ファイル `tasks.db`, ポート 8080)
zig build -Dexample=tasks
./zig-out/bin/tasks

# テスト
zig build tasks-test
```

You can change the behavior with environment variables:

| Variable | Default value | Description |
|---|---|---|
| `DATABASE_URL` | `file:tasks.db` | Accepts `file:`, `libsql://`, `turso://` |
| `PORT` | `8080` | listening port |

## API Overview

| Method | Path | Usage |
|---|---|---|
| `GET` | `/tasks` | Task list |
| `POST` | `/tasks` | Create task |
| `GET` | `/tasks/:id` | Individual acquisition |
| `PATCH` | `/tasks/:id` | Partial update |
| `DELETE` | `/tasks/:id` | Delete |
| `GET` | `/events` | SSE — Deliver task changes |
| `GET` | `/openapi.json` | Auto-generated OpenAPI 3.1 spec |
| `GET` | `/client.ts` | Auto-generated TypeScript client |
| `GET` | `/health` | liveness probe |

### Common invocation examples

```sh
# 作成
curl -X POST -H "content-type: application/json" \
     -d '{"title":"buy milk","description":"2L"}' \
     http://localhost:8080/tasks
# → 201 {"id":1,"title":"buy milk",...}

# 一覧 (ETag つき)
curl -i http://localhost:8080/tasks
# → ETag: "<hex>"
curl -i -H 'if-none-match: "<hex>"' http://localhost:8080/tasks
# → 304 Not Modified (ボディなし)

# gzip 圧縮 (1 KB 超の応答に自動付与)
curl -H 'accept-encoding: gzip' --output - http://localhost:8080/tasks | gunzip

# バリデーションエラー
curl -X POST -H 'content-type: application/json' -d '{"title":""}' \
     http://localhost:8080/tasks
# → 422 {"error_kind":"validation","errors":[{"field":"title","rule":"required",...}]}

# SSE で変更を購読
curl -N http://localhost:8080/events
# 別ターミナルから POST すると即 push される

# 仕様取得
curl http://localhost:8080/openapi.json | jq .
curl http://localhost:8080/client.ts > my-client.ts
```

---

## Explanation for each file

### `src/models.zig` — Model = SoT

```zig
pub const Task = struct {
    id: ?i64 = null,
    title: []const u8,
    description: []const u8 = "",
    done: bool = false,
    created_at: ?i64 = null,

    pub const __schema = .{
        .table = "tasks",
        .primary_key = "id",
        .indexes = .{ .{ "created_at", .index } },
        .defaults = .{ .created_at = "unixepoch()" },
        .validates = .{
            .title = .{ am.model.rule.required, am.model.rule.min_len(1), am.model.rule.max_len(120) },
            .description = .{ am.model.rule.max_len(2000) },
        },
    };
};
```

point:

- **Source of Truth as the structure is.** The DDL is determined by `__schema`, the validation is determined by `__schema.validates`, and the column type is determined by the Zig type of the field. There is no separate DSL for migration.
- `?i64 = null` is a marker for the field that is automatically filled by the DB. Repo will skip this on INSERT and read it back on RETURNING.
- Write the SQL expression as a string in `defaults`. `unixepoch()` is a SQLite built-in. Same with Turso/D1.
- `validates` runs only when passing through `c.input(Task)`. Submitting directly with `Repo.create(...)` will skip validation (assuming it is a trusted internal input).

### `src/app.zig` — State

```zig
pub const App = struct {
    db: am.db.Db,
    framework_app: ?*anyopaque = null,
    events: *EventChannel = undefined,
    jobs: *am.jobs.Queue = undefined,
};
```

State is shared across all requests, so mutable fields must be thread-safe. `db` is a vtable with internal locks, and `events` / `jobs` are protected by mutexes inside.

`framework_app` is a return link to `*am.App(App)`, which is used by the OpenAPI / client.ts handler to walk the route table at runtime (see `handlers.zig` description for details). The reason for using `*anyopaque` is that if the type definition of `App` includes `am.App(App)`, it will become a recursive reference.

#### `EventChannel`

```zig
pub const EventChannel = struct { /* ... ring buffer ... */ };
```

Tiny pub/sub for SSE. Mutex + ring buffer + monotonically increasing seq. We avoided the design caused by Mutex+Condition because `std.Thread.Mutex` disappeared from Zig 0.16, and instead used a method in which subscribers poll every 50 ms. 50 ms is a sufficiently low perceived latency on the SSE client side, and the amount of code is drastically reduced.

In the actual application, `EventChannel` will be the key for user/room/topic. In the example, all events are streamed through one channel.

### `src/handlers.zig` — Request processing

#### Input parsing with validation

```zig
pub fn createTask(c: *Ctx) !void {
    const input = (try c.input(CreateTaskInput)) orelse return;
    const created = try Tasks.create(c.db(), c.arena, .{ .title = input.title, .description = input.description });
    // ...
}
```

`c.input(T)` internally writes (1) JSON parse → 400, (2) `T.__schema.validates` application → 422, and returns `null`. Therefore, the handler side can perform a clean early return with just one `orelse return`, which is a design that is compatible with the simplicity of Hono / Express.

> **Note**: `__schema` is attached to `CreateTaskInput` / `UpdateTaskInput` separately from Model. This is to apply independent validation to the input DTO, so it is not necessary to exactly match the constraints of the Model body. For example, `UpdateTaskInput.title` is optional, so `min_len(1)` is **removed** to distinguish between ``not specified (null)'' and ``empty string.''

#### SSE

```zig
pub fn streamEvents(c: *Ctx) !void {
    var since: u64 = 0;
    if (c.req.header("last-event-id")) |s| since = std.fmt.parseInt(u64, s, 10) catch 0;

    var sse = try am.sse.open(c);
    const channel = c.state().events;

    while (waited_ms < deadline_ms) {
        if (channel.pollAfter(since)) |slot| {
            try sse.send(.{ .id = ..., .event = "task", .data = slot.bytes });
            since = slot.seq;
        } else { sleepMs(50); /* ... heartbeat ... */ }
    }
}
```

`am.sse.open(c)` internally calls `res.startStream(.{ .content_type = "text/event-stream" })` and immediately flushes the HTTP headers (status line + `transfer-encoding: chunked` + `connection: close`) to the socket. The returned `Sse` handler will ensure that each `send` pushes 1 event = 1 chunk to the FD.

Limiting connection lifetimes to 60 seconds is typical SSE practice — it also helps with idle disconnections in reverse proxies, and is useful for rebalancing when the server restarts. The `EventSource` side automatically reconnects and sends the stored `Last-Event-ID`, so you can continue playing from where you left off with `since`.

#### Background job

```zig
// setup.zig
queue.* = try am.jobs.Queue.init(alloc, database, .{ .poll_interval_ms = 200 });
try queue.handler("notify", h.notifyJob);

// handlers.zig
pub fn notifyJob(_: std.mem.Allocator, payload: []const u8) !void {
    std.log.info("[job:notify] {s}", .{payload});
}

// createTask の中で:
_ = try c.state().jobs.enqueue("notify", json_payload, .{});
```

The job is written to the `akamata_jobs` table (automatically created at startup), and a worker thread (`main.zig` and `std.Thread.spawn`) separate from the main thread picks up the pending row every `poll_interval_ms` and calls the handler. If it fails, it retries with exponential backoff and drops to `failed` state when `max_attempts` is reached.

Since this is an example, `notify` simply outputs logs, but in the actual application, it is a place to write Slack posts, email sending, pushes to external APIs, etc.

#### OpenAPI / TS Client

```zig
pub fn openapiSpec(c: *Ctx) !void {
    const fw = frameworkApp(c).?;
    const spec = try am.openapi.generate(@TypeOf(fw.*), fw, c.arena, .{ .title = "...", .version = "..." });
    try c.res.header("content-type", "application/json");
    try c.res.writeAll(spec);
}
```

`am.openapi.generate` walks every registered route. Ordinary route helpers are
included without typed schemas; `app.endpoint(...)` additionally uses
**comptime reflection** to derive JSON Schema from request and response types.

`am.client_gen.generate(...)` also reads the same route table, but you can choose the output target from TS / Zig. Incorporate `/client.ts` into your frontend build to ensure API signature changes are detected at compile time.

### `src/setup.zig` — Wiring

`setup.buildApp` is the heart of this Example. Assemble in order:

1. **State construction** — DB connection, allocating heap for Channels/Queues
2. **App building** — `am.App(App).init(alloc, state)`
3. **Return link** — `state().framework_app = @ptrCast(app_ptr)`
4. **Middleware** — `useAll` in outer-first
5. **Routes** — `app.endpoint(...)` for typed schemas and `app.get(...)` for an untyped operation

The order of middleware is important:

```
recover  ← もっとも外側。下流のあらゆる panic / return を 500 へ
logger   ← 全リクエストを記録 (400/500 を含む)
ensureSchema (Workers のみ) ← 初回リクエスト時に lazy マイグレーション
requestId ← X-Request-ID 採番。ログにも乗る
cors
secureHeaders
compress ← ハンドラ後にレスポンス本文を gzip 化
etag     ← (圧縮後の) 本文から ETag を生成。If-None-Match で 304
─── handler ───
```

Placing `compress` **before** `etag` follows the RFC 9110 guidance that ``ETags should identify expressions (including encoding)''. It also works in reverse order, but different ETags will appear for the compressed and uncompressed versions.

### `src/main.zig` — entry point

```zig
pub fn main(_: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const app_ptr = try setup.buildApp(alloc);
    defer destroy(alloc, app_ptr);

    var worker = am.jobs.Worker.init(app_ptr.state().jobs);
    const worker_thread = try std.Thread.spawn(.{}, am.jobs.Worker.run, .{&worker});
    defer { worker.stop(); worker_thread.join(); }

    try app_ptr.serve(.{ .port = port, .accept_thread_count = 4 });
}
```

`main.zig` is solely dedicated to lifecycle management:

- `DebugAllocator` — Leak detection included during development. In production, replace with `std.heap.smp_allocator` etc.
- Start/stop of worker thread is guaranteed by `defer`
- `app.serve(...)` enters normal shutdown with SIGINT / SIGTERM, so it is OK to keep blocking.

### `src/integration_test.zig` — E2E using `am.testing.Client`

```zig
test "POST /tasks creates a task" {
    const app_ptr = try newApp(alloc);
    defer destroyApp(alloc, app_ptr);

    var client = am.testing.Client(am.App(App)).init(alloc, app_ptr);
    defer client.deinit();

    var resp = try client.post("/tasks").json(.{ .title = "buy milk" }).send();
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 201), resp.status);
    const Out = struct { id: i64, title: []const u8, done: bool };
    const created = try resp.json(Out);
    try std.testing.expectEqualStrings("buy milk", created.title);
}
```

`am.testing.Client` is a thin wrapper that assembles the HTTP string and passes it directly to `app.dispatch`, so you don't have to worry about TCP/threads/port conflicts. point:

- DB is complete with `:memory:` SQLite — no state is leaked between tests
- Validation errors can be checked with `expectEqual(@as(u16, 422), resp.status)`
- Response body is typed parsed with `resp.json(YourStruct)`
- Guaranteed 0 leaks for `defer destroyApp(...)` in each test — Regressions can be detected by passing `zig build tasks-test` through CI

execution:

```sh
zig build tasks-test
# All 5 tests passed.
```

---

## Relationship with Cloudflare Workers

This sample was written with the **native (`zig build -Dexample=tasks`)** target in mind. Differences when bringing to Workers version:

| Features | Native | Workers |
|---|---|---|
| DB | SQLite / Turso / D1 All OK | D1 Required (`DATABASE_URL=d1:DB`) |
| Job queue | `am.jobs.Queue` | Rewrite to Cron Triggers + Durable Object Alarms |
| SSE | Works with `am.sse.open(c)` | Requires JS ReadableStream bridge (future task) |
| Compression | `am.mw.compress(...)` | MW is no-op because edge automatically adds |
| OpenAPI / client.ts | Behavior | Behavior |
| All `c.input` series | Operation | Operation |

If you want to run jobs and SSE on Workers, you will need to write a separate implementation by switching the `if (am.backend == .native)` guard of `setup.zig` to `else` while keeping the handler itself with the same signature.

## Reference

- Feature-specific API reference: `docs/en/handler-api.md`
- Benchmark: `docs/en/benchmarks.md`
- Architecture overview: `docs/en/architecture.md`
- Framework CLI: `tools/akamata/` (generate a new project skeleton with `akamata init <name>`)
