# Handler API (新 Hono風)

ハンドラは 1 種類のシグネチャに統一:

```zig
fn handler(c: *am.Context(State)) !void
```

## App ビルダ

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

## Context (Hono の `c` 相当)

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

## エラー

ハンドラが `error.X` を返した場合、`onError` で捕捉できる。`recover` ミドルウェアを `useAll` しておくと、未処理エラーは自動で 500 にマップ:

```zig
_ = try app.useAll(am.mw.recover(State));

fn handler(c: *am.Context(State)) !void {
    return error.SomethingBroke;
}
// → 500 + {"error_kind":"internal","message":"internal server error"}
```

## State の使い方

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

## ミドルウェアからのデータ受け渡し

```zig
// JWT mw が stash した claims を読む
fn protected(c: *am.Context(State)) !void {
    const claims = am.mw.currentJwtClaims(State, c) orelse {
        return c.json(.{ .error_kind = "unauthorized" }, 401);
    };
    try c.json(.{ .me = claims.sub }, 200);
}
```

カスタム値も `c.user_data` (opaque pointer) に詰めて受け渡せる。

## ビルトインミドルウェア

| | 説明 |
|---|---|
| `am.mw.logger(State)` | リクエストログ (method/path/status) |
| `am.mw.recover(State)` | error → 500 マップ |
| `am.mw.cors(State, opts)` | CORS ヘッダ + OPTIONS preflight |
| `am.mw.bearerAuth(State, opts)` | 固定トークン Bearer |
| `am.mw.jwt(State, opts)` | JWT HS256 検証 + claims 注入 |
| `am.mw.serveStatic(State, opts)` | 静的ファイル (native のみ) |
| `am.mw.requestId(State)` | UUIDv4 で `X-Request-ID` を採番 |
| `am.mw.rateLimit(State, opts)` | 固定ウィンドウ rate-limit |
| `am.mw.session(State, opts)` | 署名付き Cookie + 取り換え可能 Store |
| `am.mw.csrf(State, opts)` | double-submit cookie |
| `am.mw.metrics(State, opts)` | Prometheus + レイテンシヒストグラム |
| `am.mw.accessLog(State, opts)` | 構造化 JSON / Apache combined ログ |
| `am.mw.secureHeaders(State, opts)` | HSTS / CSP / X-Frame-Options などのプリセット |
| `am.mw.compress(State, opts)` | gzip/deflate (Workers では no-op) |
| `am.mw.etag(State, opts)` | SHA-256 ETag 自動付与 + 304 書き換え |

## 入力パース + バリデーション (`c.input`)

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

`c.input(T)` の挙動:

- 真に malformed な JSON → 400 を書いて null
- 不足フィールド / 制約違反 → 422 (`{error_kind, errors:[{field,rule,message}]}`) を書いて null
- 成功 → T を返す

内部では「全フィールドを optional にした projection」へ permissive parse し、validate を走らせ、欠落しているフィールドは `required` ルールで 422 に変換するという二段構えになっています。`{}` を送っても 400 ではなく 422 で field-level なエラーが返ります。

### PATCH 系の optional フィールド

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

`min_len`/`max_len`/`format`/`range`/`custom_text` は optional が null なら **ルールをスキップ** します — つまり PATCH で「送らなかったフィールド」は検証されません。`required` だけは optional null を失敗扱いにします (「optional だが必須」の表現)。

## ストリーミングと SSE

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

ストリーミング応答は `keep_alive=false` で固定、`transfer-encoding: chunked` が自動付与されます。ハンドラがエラーを返してもサーバ側は 0-chunk + flush で正規終了させるので、partial body で接続が宙吊りになることはありません。

## コンテンツネゴシエーション

```zig
fn dual(c: *am.Context(State)) !void {
    const mt = c.negotiate(&.{ "application/json", "text/html" }) orelse {
        try c.json(.{ .error_kind = "not_acceptable" }, 406);
        return;
    };
    if (std.mem.eql(u8, mt, "text/html")) try c.html(page) else try c.json(payload, 200);
}
```

`c.negotiate(...)` は RFC 9110 §12.5 準拠で q-value + specificity を評価し、サーバ側候補リストの中から最良の媒体型を返します。マッチなしの時は呼び出し側で 406 を返してください。

## フレームワーク App ポインタの取得 (`c.app()`)

OpenAPI 仕様や TypeScript クライアントを動的に出すハンドラはランタイムにルート表を歩く必要があり、その時に `*am.App(State)` を要求します。`c.app()` で取れます:

```zig
fn openapiSpec(c: *am.Context(State)) !void {
    const fw = c.app().?;
    const spec = try am.openapi.generate(@TypeOf(fw.*), fw, c.arena, .{ .title = "...", .version = "..." });
    try c.res.header("content-type", "application/json");
    try c.res.writeAll(spec);
}
```

unit test など `app.dispatch` を介さない経路では null になります。

## ライフサイクル管理 (`app.own`)

State に長寿命のヒープリソース (SSE 用 channel、ジョブキュー、外部サービスのクライアントなど) を持たせたい場合は `app.own(ptr)` で寿命を App に紐付けてください。`app.deinit()` が登録の逆順に呼び出して `ptr.deinit()` を呼んだのち `gpa.destroy(ptr)` します:

```zig
const events = try alloc.create(EventChannel);
events.* = EventChannel.init(alloc);
try app.own(events);
app.state().events = events;
```

`Child.deinit(*Self)` または `Child.deinit(*Self, Allocator)` は自動検出されます。

## 同期プリミティブ (`am.sync`)

Zig 0.16 std からは `std.Thread.Mutex` / `Condition` が外れたので、Akamata は libc pthread を薄ラップした置き換えを提供しています:

```zig
const m = am.sync.Mutex.init();  // = am.Mutex.init()
defer m.deinit();
m.lock(); defer m.unlock();
```

`am.sync.Condition` も同様。`am.Mutex` / `am.Condition` は同じ型のエイリアスです。共有 State のフィールドはこれらか `std.atomic.Value(T)` で守ってください。

## テストクライアント

`am.testing.Client` で TCP / threads / port 競合なしに app をテストできます:

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

`resp.json(T)` で typed parse、`resp.header(name)` でヘッダ取得。詳細は `examples/tasks/src/integration_test.zig` 参照。
