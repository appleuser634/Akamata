# Example: tasks — ベストプラクティス API

`examples/tasks/` は Akamata の代表的な機能をひとつのアプリにまとめたタスク管理 REST API です。新しいアプリを書き始めるときの叩き台として、また「この機能はどう使うんだろう?」というリファレンスとして使えるよう、コードはコメント多めで書かれています。

このドキュメントは Example の全体像と、各機能が **なぜ** その形で組まれているかを解説します。Akamata 本体の API リファレンスは `docs/handler-api.md` を参照してください。

## このサンプルが扱う機能

| 機能 | 実装場所 | 関連 IMP |
|---|---|---|
| Model + 自動マイグレーション + バリデーション | `src/models.zig`, `src/handlers.zig` の `c.input()` | — |
| OpenAPI 3.1 自動生成 | `src/setup.zig` の `app.endpoint(...)`, `src/handlers.zig` の `openapiSpec` | IMP-2 |
| 型安全 TypeScript クライアント生成 | `src/handlers.zig` の `typescriptClient` | IMP-10 |
| ストリーミング + SSE | `src/handlers.zig` の `streamEvents`, `src/app.zig` の `EventChannel` | IMP-1 |
| 永続ジョブキュー | `src/setup.zig` の Queue 構築, `src/handlers.zig` の `notifyJob` | IMP-5 |
| ミドルウェアスタック (logger / recover / requestId / cors / secureHeaders / compress / etag) | `src/setup.zig` の `useAll(...)` | IMP-3, IMP-4, IMP-9 |
| `am.testing.Client` での E2E テスト | `src/integration_test.zig` | IMP-6 |

リソースは `tasks` 1 テーブルだけのシンプルな CRUD ですが、上記の機能はすべて **実コード** で動いているので、`zig build tasks-test` でテストとして検証できます。

## ディレクトリ構成

```
examples/tasks/
└── src/
    ├── app.zig              # State 型 + EventChannel (SSE pub/sub)
    ├── models.zig           # `Task` モデル + 自動マイグレーション manifest
    ├── handlers.zig         # ルートごとのハンドラ実装
    ├── setup.zig            # App ビルド + ミドルウェアチェーン + ルート登録
    ├── main.zig             # native エントリ
    └── integration_test.zig # am.testing.Client でのテスト
```

## ビルド & 実行

```sh
# サーバ起動 (default: SQLite ファイル `tasks.db`, ポート 8080)
zig build -Dexample=tasks
./zig-out/bin/tasks

# テスト
zig build tasks-test
```

環境変数で挙動を変えられます:

| 変数 | 既定値 | 説明 |
|---|---|---|
| `DATABASE_URL` | `file:tasks.db` | `file:`, `libsql://`, `turso://` を受け付ける |
| `PORT` | `8080` | listen ポート |

## API の概要

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/tasks` | タスク一覧 |
| `POST` | `/tasks` | タスク作成 |
| `GET` | `/tasks/:id` | 個別取得 |
| `PATCH` | `/tasks/:id` | 部分更新 |
| `DELETE` | `/tasks/:id` | 削除 |
| `GET` | `/events` | SSE — タスク変更を配信 |
| `GET` | `/openapi.json` | 自動生成された OpenAPI 3.1 spec |
| `GET` | `/client.ts` | 自動生成された TypeScript クライアント |
| `GET` | `/health` | liveness probe |

### よくある呼び出し例

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

## ファイルごとの解説

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

ポイント:

- **構造体がそのまま真の出処 (Source of Truth)**。`__schema` から DDL、`__schema.validates` からバリデーション、フィールドの Zig 型からカラム型が決まります。マイグレーション用の別 DSL はありません。
- `?i64 = null` は「DB が自動で埋める」フィールドのマーカ。Repo は INSERT 時にこれをスキップし、RETURNING で読み戻します。
- `defaults` には SQL 式を文字列で書きます。`unixepoch()` は SQLite のビルトイン。Turso / D1 でも同じ。
- `validates` は `c.input(Task)` を経由した時だけ走ります。直接 `Repo.create(...)` で投入すると検証はスキップされます (信頼できる内部入力という想定)。

### `src/app.zig` — State

```zig
pub const App = struct {
    db: am.db.Db,
    framework_app: ?*anyopaque = null,
    events: *EventChannel = undefined,
    jobs: *am.jobs.Queue = undefined,
};
```

State は全リクエストで共有されるので、可変フィールドはスレッドセーフでなければなりません。`db` は内部にロックを持つ vtable、`events` / `jobs` は中の Mutex で保護されています。

`framework_app` は `*am.App(App)` への戻りリンクで、OpenAPI / client.ts ハンドラがランタイムにルート表を歩くために使います (詳細は `handlers.zig` の解説)。`*anyopaque` にしているのは、`App` の型定義が `am.App(App)` を含むと再帰参照になるためです。

#### `EventChannel`

```zig
pub const EventChannel = struct { /* ... ring buffer ... */ };
```

SSE 用の極小 pub/sub。Mutex + リング・バッファ + 単調増加 seq です。Mutex+Condition で起こす設計は `std.Thread.Mutex` が Zig 0.16 から消えた都合上避け、subscribers が 50 ms ごとにポーリングする方式にしました。SSE クライアント側の体感レイテンシとしては 50 ms は十分小さく、コード量も激減します。

実アプリでは `EventChannel` をユーザ / ルーム / トピックでキーにすることになるでしょう。Example では 1 本の channel で全イベントを流しています。

### `src/handlers.zig` — リクエスト処理

#### バリデーション付き入力パース

```zig
pub fn createTask(c: *Ctx) !void {
    const input = (try c.input(CreateTaskInput)) orelse return;
    const created = try Tasks.create(c.db(), c.arena, .{ .title = input.title, .description = input.description });
    // ...
}
```

`c.input(T)` は (1) JSON パース → 400、(2) `T.__schema.validates` 適用 → 422 を内部で書き、`null` を返してきます。だからハンドラ側は `orelse return` 1 つでクリーンに早期 return できる、というのが Hono / Express のシンプルさと相性が良い設計です。

> **Note**: `CreateTaskInput` / `UpdateTaskInput` には Model とは別に `__schema` を付けています。これは入力 DTO に独立したバリデーションをかけるためで、Model 本体の制約と完全一致させる必要はありません。例えば `UpdateTaskInput.title` は optional なので `min_len(1)` を **外して** あります — 「指定しなかった (null)」と「空文字列」を区別するためです。

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

`am.sse.open(c)` は内部で `res.startStream(.{ .content_type = "text/event-stream" })` を呼び、HTTP ヘッダ (ステータス行 + `transfer-encoding: chunked` + `connection: close`) を即座にソケットへ flush します。返ってきた `Sse` ハンドラは各 `send` で 1 イベント = 1 chunk を確実に FD まで押し出します。

接続寿命を 60 秒で切っているのは典型的な SSE の慣習です — リバースプロキシのアイドル切断対策にもなり、サーバ再起動時のリバランスにも有利です。`EventSource` 側は自動で再接続し、保持していた `Last-Event-ID` を送ってくれるので、`since` で続きから流せます。

#### バックグラウンドジョブ

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

ジョブは `akamata_jobs` テーブル (起動時に自動で作られる) に書き込まれ、メインスレッドとは別の worker thread (`main.zig` で `std.Thread.spawn`) が `poll_interval_ms` ごとに pending 行を拾ってハンドラを呼びます。失敗時は指数バックオフで再試行、`max_attempts` 到達で `failed` 状態に落ちます。

実例なので `notify` は単にログを吐くだけですが、実アプリでは Slack 投稿、メール送信、外部 API への push などを書く場所です。

#### OpenAPI / TS クライアント

```zig
pub fn openapiSpec(c: *Ctx) !void {
    const fw = frameworkApp(c).?;
    const spec = try am.openapi.generate(@TypeOf(fw.*), fw, c.arena, .{ .title = "...", .version = "..." });
    try c.res.header("content-type", "application/json");
    try c.res.writeAll(spec);
}
```

`am.openapi.generate` は `app.routes` を歩き、`app.endpoint(method, path, handler, am.openapi.Spec(.{...}))` で登録されたルートだけを spec に含めます。**comptime reflection** で各リクエスト / レスポンス型から JSON Schema を導出するので、Zig 構造体を編集すれば仕様も同時に更新されます — 「コードとドキュメントがズレる」事故が起きません。

`am.client_gen.generate(...)` も同じルート表を読みますが、出力ターゲットを TS / Zig から選べます。`/client.ts` をフロントエンドのビルドに組み込めば、API シグネチャ変更がコンパイル時に検出できるようになります。

### `src/setup.zig` — Wiring

`setup.buildApp` がこの Example の心臓部です。順序を守って組み立てます:

1. **State 構築** — DB 接続、Channels/Queues のヒープ確保
2. **App 構築** — `am.App(App).init(alloc, state)`
3. **戻りリンク** — `state().framework_app = @ptrCast(app_ptr)`
4. **ミドルウェア** — outer-first で `useAll`
5. **ルート** — `app.endpoint(...)` (ドキュメント対象) と `app.get(...)` (それ以外)

ミドルウェアの順序は重要です:

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

`compress` を `etag` の **前** に置いているのは「ETag は表現 (encoding 込み) を識別するべき」という RFC 9110 のガイダンスに従ったものです。逆順でも動きますが、圧縮版とそうでない版で別の ETag が出ます。

### `src/main.zig` — エントリポイント

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

`main.zig` はライフサイクル管理だけに専念しています:

- `DebugAllocator` — 開発中はリーク検出付き。プロダクションでは `std.heap.smp_allocator` などへ差し替え
- worker thread の起動/停止は `defer` で保証
- `app.serve(...)` は SIGINT / SIGTERM で正規シャットダウンに入るのでブロックしっぱなしで OK

### `src/integration_test.zig` — `am.testing.Client` を使った E2E

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

`am.testing.Client` は HTTP 文字列を組み立ててから `app.dispatch` に直接渡す薄ラッパなので、TCP / threads / port 競合のことは考えなくて済みます。ポイント:

- DB は `:memory:` SQLite で完結 — テスト間で状態が漏れません
- バリデーションエラーは `expectEqual(@as(u16, 422), resp.status)` で確認できる
- レスポンス本文は `resp.json(YourStruct)` で型付きパース
- 各 test の `defer destroyApp(...)` でリーク 0 を保証 — `zig build tasks-test` を CI に通せばリグレッション検出できる

実行:

```sh
zig build tasks-test
# All 5 tests passed.
```

---

## Cloudflare Workers との関係

このサンプルは **native (`zig build -Dexample=tasks`)** ターゲットを前提に書かれています。Workers 版に持っていく際の差分:

| 機能 | Native | Workers |
|---|---|---|
| DB | SQLite / Turso / D1 すべて OK | D1 必須 (`DATABASE_URL=d1:DB`) |
| ジョブキュー | `am.jobs.Queue` | Cron Triggers + Durable Object Alarms へ書き換え |
| SSE | `am.sse.open(c)` で動作 | JS ReadableStream bridge が必要 (将来タスク) |
| 圧縮 | `am.mw.compress(...)` | edge が自動付与するため MW は no-op |
| OpenAPI / client.ts | 動作 | 動作 |
| `c.input` 系すべて | 動作 | 動作 |

ジョブと SSE を Workers でも動かしたい場合は、ハンドラ自体は同じシグネチャのまま、`setup.zig` の `if (am.backend == .native)` ガードを `else` 側に switch する形で別実装を書き分けることになります。

## 参考

- 機能ごとの API リファレンス: `docs/handler-api.md`
- ベンチマーク: `docs/benchmarks.md`
- アーキテクチャ概観: `docs/architecture.md`
- フレームワーク CLI: `tools/akamata/` (`akamata init <name>` で新規プロジェクトのスケルトンを生成)
