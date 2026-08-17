# Historical API redesign record

> This is a historical design record, not the current API reference. Some signatures and examples were superseded. See [Handler API](handler-api.md) and the current source for supported interfaces.

Evolving Akamata into a web framework that can be written in the same way as Hono.

## the goal

```zig
// src/main.zig — これだけで Cloudflare Workers にも Containers にもデプロイ可能
const std = @import("std");
const am = @import("akamata");

const App = am.App(.{}); // state なしなら .{} 一つ

pub fn main() !void {
    var app = try App.init(std.heap.smp_allocator);
    defer app.deinit();

    _ = try app.get("/", hello);
    _ = try app.get("/users/:id", showUser);
    _ = try app.post("/users", createUser);
    _ = try app.use("/api/*", am.mw.bearerAuth("secret"));

    try app.serve(.{ .port = 8080 });
}

fn hello(c: *am.Context) !void {
    try c.text("Hello Akamata");
}

fn showUser(c: *am.Context) !void {
    const id = try c.req.param("id");
    try c.json(.{ .id = id }, 200);
}

fn createUser(c: *am.Context) !void {
    const Body = struct { name: []const u8 };
    const body = try c.req.json(Body);
    try c.json(.{ .name = body.name, .created = true }, 201);
}
```

Share the same `main.zig` in Workers mode and switch only the build target:

```bash
# Containers
akamata deploy containers

# Workers
akamata deploy workers
```

## Architecture

```
┌──────────────────────────────────────────┐
│  user app (src/main.zig 1ファイル)          │
└──────────────────┬──────────────────────┘
                   │ Hono風API
                   v
┌──────────────────────────────────────────┐
│  am.App / am.Context (新)                 │
│   ├─ ランタイムビルダのRouter (新)         │
│   ├─ Path-level middleware chain (new)     │
│   └─ ビルトインmw: cors/jwt/bearer/static  │
└──────────────────┬──────────────────────┘
                   │
                   v
┌──────────────────────────────────────────┐
│  既存 transport 層 (HTTP + WS + DB)       │
└──────────────────────────────────────────┘
```

## API details

### App (with state as type parameter)

```zig
pub fn App(comptime State: type) type {
    return struct {
        // ...
        pub fn init(gpa: Allocator) !App
        pub fn deinit(self: *App) void
        pub fn state(self: *App) *State

        // ルート登録 (ポインタを返してチェーン可能だが、慣用は破棄)
        pub fn get(self: *App, path: []const u8, h: Handler) !*App
        pub fn post(self: *App, path: []const u8, h: Handler) !*App
        pub fn put(self: *App, path: []const u8, h: Handler) !*App
        pub fn delete(self: *App, path: []const u8, h: Handler) !*App
        pub fn patch(self: *App, path: []const u8, h: Handler) !*App
        pub fn options(self: *App, path: []const u8, h: Handler) !*App
        pub fn all(self: *App, path: []const u8, h: Handler) !*App
        pub fn ws(self: *App, path: []const u8, h: Handler) !*App

        // Middleware
        pub fn use(self: *App, path_pattern: []const u8, mw: Middleware) !*App
        pub fn useAll(self: *App, mw: Middleware) !*App

        // グルーピング
        pub fn basePath(self: *App, prefix: []const u8) !*Group
        pub fn route(self: *App, prefix: []const u8, sub: *App) !void

        // ハンドリング
        pub fn notFound(self: *App, h: Handler) void
        pub fn onError(self: *App, h: ErrorHandler) void

        // 起動 (native のみ)
        pub fn serve(self: *App, opts: ServeOptions) !void
        // WASM 用エクスポート (Workers モードで自動使用)
        pub fn dispatchBytes(self: *App, request_bytes: []const u8, out: *ArrayList(u8)) !void
    };
}
```

`Handler` is type erased and unified to `*const fn(*Context) anyerror!void`. Access to state is `c.app.state()`.

### Context (equivalent to Hono's `c`)

```zig
pub const Context = struct {
    // 既存
    req: Request,
    res: Response,
    arena: Allocator,

    // 中身
    params_map: Params,
    state_ptr: *anyopaque,

    // Hono風 API
    pub fn json(c: *Context, value: anytype, status: u16) !void
    pub fn text(c: *Context, body: []const u8) !void
    pub fn html(c: *Context, body: []const u8) !void
    pub fn redirect(c: *Context, url: []const u8, status: u16) !void
    pub fn notFound(c: *Context) !void
    pub fn status(c: *Context, code: u16) void
    pub fn header(c: *Context, name: []const u8, value: []const u8) !void
    pub fn body(c: *Context, bytes: []const u8) !void
};

// Request は c.req.* で薄くラップ
pub const Request = struct {
    // 既存
    method: Method,
    path: []const u8,
    query_raw: []const u8,
    body_raw: []const u8,
    headers: []const Header,

    // Hono風
    pub fn param(r: *Request, name: []const u8) ![]const u8
    pub fn paramOrNull(r: *Request, name: []const u8) ?[]const u8
    pub fn query(r: *Request, name: []const u8) ?[]const u8
    pub fn queries(r: *Request, name: []const u8) []const []const u8  // 複数値
    pub fn header(r: *Request, name: []const u8) ?[]const u8
    pub fn json(r: *Request, comptime T: type) !T
    pub fn text(r: *Request) []const u8
    pub fn arrayBuffer(r: *Request) []const u8
};
```

Helper for accessing state:

```zig
pub fn State(c: *Context, comptime T: type) *T {
    return @ptrCast(@alignCast(c.state_ptr));
}
// 使い方: const app = am.State(c, MyApp);
```

### Built-in middleware (`am.mw.*`)

Minimum set of 6 pieces:

| Middleware | Description | Scope |
|---|---|---|
| `am.mw.logger()` | Request log (existing) | both |
| `am.mw.recover()` | Convert panic / error to 500 (existing) | both |
| `am.mw.cors(.{...})` | CORS header addition | both |
| `am.mw.bearerAuth(.{ .token = ... })` | Fixed token | both |
| `am.mw.jwt(.{ .secret = ..., .verify = ... })` | JWT validation + inject sub into c | both |
| `am.mw.serveStatic(.{ .root = "public/" })` | Static file | native only |
| `am.mw.compress()` | gzip (deferred) | native only |

A style of "middleware with method names as they are" following Hono.

### Routers (per-path middleware and groups)

```zig
// パス単位 use
_ = try app.use("/api/*", am.mw.cors(.{ .origin = "*" }));
_ = try app.use("/api/admin/*", am.mw.bearerAuth(.{ .token = admin_token }));

// basePath / sub-app
var api = try app.basePath("/api/v1");   // returns *Group which has the same .get/.post/.use API
_ = try api.get("/posts", listPosts);
_ = try api.post("/posts", createPost);

// 別 App として組み立てて mount
var users_app = try App.init(alloc);
_ = try users_app.get("/", listUsers);
_ = try users_app.get("/:id", showUser);
try app.route("/users", &users_app);
```

Choice of implementation: Trie router or linear search. MVP uses linear search (fast enough assuming number of routes < 200).

### Error handling

Like Hono's `HTTPException`:

```zig
pub const HTTPException = error{
    BadRequest, Unauthorized, Forbidden, NotFound,
    Conflict, UnprocessableEntity, InternalServerError,
};

// ハンドラ内
return HTTPException.NotFound; // → 自動で404 + JSON {"error":"not_found"}
```

All errors can be caught with `app.onError(handler)`.

### Launch/Deploy

```zig
// 同じソースで両方動く: app.serve がコンパイル時に backend で分岐
try app.serve(.{ .port = 8080 });
// native → std.Io.Threaded + std.Io.net.listen
// workers → setDispatch + export を自動的に行う
```

When you call `serve` in Workers mode, `am.runtime.workers.setDispatch(dispatchBytes)` is internally loaded and `akamata_init` is exported.

## akamata-cli

Another binary written in Zig under `tools/akamata/`. Generate `zig-out/bin/akamata` from `zig build cli`.

### Command

```bash
akamata init my-app --target=workers|containers|both
  # 雛形ディレクトリを生成
  # - build.zig, build.zig.zon (akamata を path 依存で参照)
  # - src/main.zig (Hello world)
  # - .gitignore, README.md
  # - target=workers: wrangler.toml, deploy/worker/index.mjs
  # - target=containers: Dockerfile
  # - target=both: 両方

akamata dev
  # zig build run -Dbackend=native  を呼ぶショートカット
  # ホットリロードは MVP では非対応 (`watchexec` 推奨をdocsに)

akamata build [--workers|--containers|--all]
  # それぞれ zig build -Dbackend=workers / -Dtarget=x86_64-linux-musl をラップ

akamata deploy [--workers|--containers]
  # workers: build → wrangler deploy
  # containers: build → docker build → wrangler containers deploy

akamata db [--local|--remote] <sql-file>
  # D1 マイグレーション ショートカット
  # Equivalent to wrangler d1 execute <name> --file=...
```

### init template configuration

```
my-app/
├── build.zig                   # akamata を path 依存で取り込む
├── build.zig.zon
├── README.md
├── .gitignore
├── src/
│   └── main.zig                # Hello world
└── (target=workers)
    ├── wrangler.toml
    └── deploy/worker/index.mjs
   (target=containers)
    └── Dockerfile
```

The `build.zig` template just calls akamata's build helper:

```zig
const std = @import("std");
const akamata_build = @import("akamata").akamata_build;

pub fn build(b: *std.Build) void {
    akamata_build.app(b, .{
        .name = "my-app",
        .root_source_file = "src/main.zig",
    });
}
```

Now the `-Dbackend`/`-Dtarget`/`-Doptimize` flags will be automatically aligned.

## Migration Planning (Full Course)

### Phase α: Framework new API (3 days)

α1. `src/app.zig` — Hono style `App(State)` implementation. runtime Router, basePath, route, use(path_pattern), onError
α2. `src/context.zig` rewrite — `c.req.param/json/query`, `c.json/text/html/redirect`, state helper
α3. `src/request.zig` extension — query parser, `json(comptime T)` method
α4. `src/mw/cors.zig`, `bearer.zig`, `jwt.zig`, `static.zig` — Built-in middleware
α5. `src/runtime.zig` — `app.serve()` automatically branches in backend
α6. `src/build_helpers/akamata_build.zig` — `akamata_build.app(b, opts)` template

### Phase β: akamata-cli (2 days)

β1. `tools/akamata/src/main.zig` — CLI entry
β2. `init` subcommand + template (embedFile)
β3. `dev` / `build` / `deploy` / `db` subcommands
β4. `b.step("cli", ...)` added with `build.zig`

### Phase γ: Migration of existing examples to new API (2 days)

γ1. Rewrite `examples/chat/src/main.zig` to new API
γ2. Fully rewritten `docs/en/`
γ3. Old `Router(App)` / `Server(App)` will remain for the time being with only the deprecation mark left** (for compatibility)

### Phase δ: Test + CI (1 day)

δ1. `tests/app_test.zig` (New API test)
δ2. Add cli build + init template operation check to CI
δ3. Rewritten README/quickstart with new API

Total 8 days.

## Compatibility

- The old `Router(App).build(&.{...})` API will remain for the time being and will be guided by the `@deprecated` comment.
- `Server(App)` is left as an internal implementation, and `App` is a thin layer that calls `Server` internally.
- Existing tests pass as is (`tests/router_test.zig`, etc.)

## Main risks

1. **state type erase vs `App(comptime State: type)`** — Hono is a state generic type, but it is troublesome to mix middleware between different states. `App` itself is a type parameter, Handler is `*const fn(*Context) anyerror!void` without State, and `State(c, MyT)` is obtained via Context, which balances ergonomics and type safety.
2. **Runtime Router Performance** — 200 routes × 100k qps = 20M ops/sec ≒ 50ns/match with linear search, no problem. Trie is v2
3. **`App.serve` in WASM** — `serve` branches at the backend, so native code and workers code come from the same source. This is already achieved with the current handler abstraction, so it can be inherited.
4. **CLI binary size** — Embedding the template with embedFile takes a few MB, but it is acceptable.

## Final policy (agreed on 2026-05-22)

1. **state type**: `App(MyState)` generic (Zig-like type safety). Handler is `*const fn(*Context(State)) anyerror!void`, Context also has State parameter
2. **Group type**: `app.basePath("/api/v1")` also returns the same `*App(State)` type. Just has a prefix inside like Hono
3. **CLI external dependency**: `wrangler` / `docker` is not included in the CLI and is called in a child process (equivalent to `std.process.Child`). Information message if not installed
4. **Scope**: Full course (Phase α+β+γ+δ), including migration of the chat example to the new API
