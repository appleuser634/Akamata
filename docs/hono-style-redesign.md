# Hono風 DX へのリデザイン

Akamata を、Hono と同じ感覚で書ける Web フレームワークに進化させる。

## 目標

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

Workers モードでも同じ `main.zig` を共有し、ビルドターゲットだけ切り替える:

```bash
# Containers
akamata deploy containers

# Workers
akamata deploy workers
```

## アーキテクチャ

```
┌──────────────────────────────────────────┐
│  user app (src/main.zig 1ファイル)          │
└──────────────────┬──────────────────────┘
                   │ Hono風API
                   v
┌──────────────────────────────────────────┐
│  am.App / am.Context (新)                 │
│   ├─ ランタイムビルダのRouter (新)         │
│   ├─ パス単位ミドルウェアチェーン (新)     │
│   └─ ビルトインmw: cors/jwt/bearer/static  │
└──────────────────┬──────────────────────┘
                   │
                   v
┌──────────────────────────────────────────┐
│  既存 transport 層 (HTTP + WS + DB)       │
└──────────────────────────────────────────┘
```

## API 詳細

### App (型パラメータで state を持つ)

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

        // ミドルウェア
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

`Handler` は型イレーズして `*const fn(*Context) anyerror!void` に統一。state へのアクセスは `c.app.state()`。

### Context (Hono の `c` 相当)

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

state へのアクセス用ヘルパ:

```zig
pub fn State(c: *Context, comptime T: type) *T {
    return @ptrCast(@alignCast(c.state_ptr));
}
// 使い方: const app = am.State(c, MyApp);
```

### ビルトインミドルウェア (`am.mw.*`)

最小セット 6 個:

| Middleware | 説明 | スコープ |
|---|---|---|
| `am.mw.logger()` | リクエストログ (既存) | both |
| `am.mw.recover()` | panic / error を500に変換 (既存) | both |
| `am.mw.cors(.{...})` | CORS ヘッダ付与 | both |
| `am.mw.bearerAuth(.{ .token = ... })` | 固定トークン | both |
| `am.mw.jwt(.{ .secret = ..., .verify = ... })` | JWT 検証 + sub を c に注入 | both |
| `am.mw.serveStatic(.{ .root = "public/" })` | 静的ファイル | native のみ |
| `am.mw.compress()` | gzip (後回し) | native のみ |

Hono に倣って "メソッド名がそのままミドルウェア" のスタイル。

### ルーター (パス単位ミドルウェアとグループ)

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

実装は Trie ルータか線形検索の選択。MVP は線形検索でいく (ルート数 < 200 想定で十分速い)。

### エラーハンドリング

Hono の `HTTPException` 風に:

```zig
pub const HTTPException = error{
    BadRequest, Unauthorized, Forbidden, NotFound,
    Conflict, UnprocessableEntity, InternalServerError,
};

// ハンドラ内
return HTTPException.NotFound; // → 自動で404 + JSON {"error":"not_found"}
```

`app.onError(handler)` で全エラーをcatch可能。

### 起動 / デプロイ

```zig
// 同じソースで両方動く: app.serve がコンパイル時に backend で分岐
try app.serve(.{ .port = 8080 });
// native → std.Io.Threaded + std.Io.net.listen
// workers → setDispatch + export を自動的に行う
```

Workers モードで `serve` を呼ぶと、内部で `am.runtime.workers.setDispatch(dispatchBytes)` を仕込んで`akamata_init`をexportする。

## akamata-cli

`tools/akamata/` 配下に Zig で書く別バイナリ。`zig build cli` で `zig-out/bin/akamata` を生成。

### コマンド

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
  # = wrangler d1 execute <name> --file=... 相当
```

### init テンプレート構成

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

`build.zig` 雛形は akamata の build helper を呼ぶだけにする:

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

これで`-Dbackend`/`-Dtarget`/`-Doptimize` フラグが自動で揃う。

## 移行計画 (フルコース)

### Phase α: フレームワーク新API (3 日)

α1. `src/app.zig` — Hono風 `App(State)` 実装。runtime Router、basePath、route、use(path_pattern)、onError
α2. `src/context.zig` リライト — `c.req.param/json/query`, `c.json/text/html/redirect`, state ヘルパ
α3. `src/request.zig` 拡張 — query パーサ、`json(comptime T)` メソッド
α4. `src/mw/cors.zig`, `bearer.zig`, `jwt.zig`, `static.zig` — ビルトインミドルウェア
α5. `src/runtime.zig` — `app.serve()` が backend で自動分岐
α6. `src/build_helpers/akamata_build.zig` — `akamata_build.app(b, opts)` テンプレート

### Phase β: akamata-cli (2 日)

β1. `tools/akamata/src/main.zig` — CLI エントリ
β2. `init` サブコマンド + テンプレート (embedFile)
β3. `dev` / `build` / `deploy` / `db` サブコマンド
β4. `build.zig` で `b.step("cli", ...)` 追加

### Phase γ: 既存 examples の新API移行 (2 日)

γ1. `examples/chat/src/main.zig` を新API に書き換え
γ2. `examples/mobus/src/main.zig` 同上 (26 endpoints)
γ3. `docs/` を全面リライト
γ4. 旧 `Router(App)` / `Server(App)` は **非推奨マークだけ残して当面は残置** (互換性のため)

### Phase δ: テスト + CI (1 日)

δ1. `tests/app_test.zig` (新 API テスト)
δ2. CI に cli ビルド + init テンプレートの動作確認を追加
δ3. README / quickstart を新 API で書き直し

合計 8 日。

## 互換性

- 旧 `Router(App).build(&.{...})` API は当面残し、`@deprecated` コメントで誘導
- `Server(App)` は内部実装として残し、`App` は内部で `Server` を呼ぶ薄い層に
- 既存テストはそのまま通る (`tests/router_test.zig` 等)

## 主要リスク

1. **state 型イレーズ vs `App(comptime State: type)`** — Hono は state ジェネリック型だが、middleware を異なる State 間で混ぜると面倒。`App` 自体は型パラメータ、Handler は `*const fn(*Context) anyerror!void` で State なし、Context 経由で `State(c, MyT)` 取得、という ergonomics と型安全のバランスを取る
2. **Runtime Router のパフォーマンス** — 線形検索で 200 ルート × 100k qps = 20M ops/sec ≒ 50ns/match で問題なし。Trie は v2 で
3. **WASM での `App.serve`** — `serve` が backend で分岐するため、native コードと workers コードが同じソースから出る。これは現在の handler 抽象では既に達成済みなので継承
4. **CLI バイナリサイズ** — embedFile でテンプレートを埋め込むと数MBになるが許容範囲

## 確定方針 (2026-05-22 合意済み)

1. **state 型**: `App(MyState)` ジェネリック (Zig らしい型安全)。Handler は `*const fn(*Context(State)) anyerror!void`、Context も State パラメータ付き
2. **Group 型**: `app.basePath("/api/v1")` も同じ `*App(State)` 型を返す。Hono と同じく内部に prefix を持つだけ
3. **CLI 外部依存**: `wrangler` / `docker` は CLI に同梱せず、子プロセスで呼ぶ (`std.process.Child` 相当)。未インストールなら案内メッセージ
4. **スコープ**: フルコース (Phase α+β+γ+δ)。examples/chat と mobus も新APIへ移行
