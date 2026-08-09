# Handler API reference

ハンドラは 1 種類のシグネチャに統一:

```zig
fn handler(c: *am.Context(State)) !void
```

特記がない限り、返されるsliceとparse済みの値はrequest arena上にあり、handler return後に保持できません。operationはZigのerror unionを返し、application errorは`app.onError`または`am.mw.recover`で処理できます。nativeとWorkersのhandler signatureは共通ですが、socketやfilesystemを必要とするAPIは各節で明記します。

## Reference map

| 分野 | 主なsignature／entry point | return value、error、lifetime、backend |
|---|---|---|
| App | `am.App(State).init(allocator, state)` | appを所有して返します。route登録はallocation errorを返す場合があり、最後に`deinit()`します。route tableはnative／Workers共通です。 |
| Context | `*am.Context(State)` | 1 request中だけborrowします。`c.state()`はapplication-owned、`c.arena`の値はrequest-ownedです。 |
| Request | `c.req.param`、`paramAs`、`query`、`queries`、`json(T)`、`body`、`header` | missing／parse／allocation errorは該当するerror unionで返ります。sliceとdecode済みbodyはrequest-scopedです。 |
| Response | `c.json(value, status)`、`text`、`html`、`redirect`、`header`、`status` | 現在のresponseへ書き込み、serialization／allocation errorを返す場合があります。streaming response commit後に別のbodyを書かないでください。 |
| Database | `c.db()`の後に`Db.prepare`／`exec`、`Stmt.bind`／`step`／`column*` | `c.db()`でrequest instrumentationが有効になります。statementは`deinit()`までbackend resourceを所有します。SQLite、D1、Tursoでfacadeは共通です。 |
| Model／repository | `am.model.repo(Model)`と`Model.__schema` | comptime生成のCRUDです。read結果と文字列fieldは指定したarena上にあります。DB／validation errorを伝播します。 |
| HTTP client | `c.fetch(am.http_client.Request)`または`am.http_client.send(allocator, request)` | responseまたはerrorを返し、response sliceは指定allocator（`c.fetch`では`c.arena`）上にあります。`c.fetch`はtimingを記録し、native／Workersで利用できます。URL全体をmetrics labelには使いません。 |
| 認証 | `am.mw.bearerAuth`、`am.mw.jwt`、`am.auth.jwt`、`am.auth.password` | 認証失敗時はmiddlewareが401を返します。JWT middlewareはHS256だけを受け付け、差し替え可能なwall clockで`exp`／`nbf`を検証します。 |
| WebSocket | `app.ws(path, handler)`と`am.ws.upgrade(...)` | native socketはZigで処理します。WorkersではWebSocket guideに記載したJavaScript／Durable Object integrationを使います。 |
| SSE／streaming | `am.sse.open(c)`と`c.startStream(options)` | native専用です。writerはrequest-scopedでheaderをcommitし、write／flushはI/O errorを返す場合があります。 |

backend固有の挙動は[Database backends](db-backends.md)、[WebSocket](websocket.md)、[Observability](observability.md)を参照してください。

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

## Context

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

## Built-in middleware

`app.useAll(middleware)`はすべてのrouteへ、`app.use(pattern, middleware)`は一致したpathへmiddlewareを適用します。optionsは`comptime`なので、文字列はapplication lifetime中有効である必要があります。

| Signature | 主なdefaultと注意点 |
|---|---|
| `recover(State)` | 未処理のhandler errorを汎用的な500 responseへ変換します。error文字列は公開しません。 |
| `logger(State)` | method／path／statusを出す開発向けlogです。本番のstructured outputには`accessLog`を使います。 |
| `requestId(State)` | 印字可能で64 byte以下の`X-Request-ID`を引き継ぐかUUIDv4を生成します。`c.requestId()`で取得できます。 |
| `accessLog(State, format)` | `.json`または`.combined`を指定します。`accessLogWithOptions`はJSONがdefaultで、raw pathを除外します。 |
| `metrics(State, *MetricsCounters)` | `.web` profileでrequest metricsを記録します。`metricsWithConfig`では`.fast`も選択でき、`metricsHandler`で公開します。 |
| `serverTiming(State, options)` | defaultは無効、`include_named_spans = true`です。component名を公開してよい場合だけ有効にします。 |
| `cors(State, options)` | origin `*`、一般的なmethod、`content-type,authorization`、credentials無効がdefaultです。credential付きbrowser requestでwildcard originを使わないでください。 |
| `bearerAuth(State, options)` | 固定`token`が必須で、realmは`Restricted`です。secretをsource codeへ直接書かないでください。 |
| `jwt(State, options)` | HS256 `secret`が必須で、defaultではclaimsを`user_data`へ保存します。defaultで`exp`を必須とし、`exp`／`nbf`を検証します。policyは`require_exp`、`leeway_seconds`、`reject_future_iat`、`now_fn`で設定します。 |
| `session(State, options)` | 32 bytes以上のHMAC secretが必須です。署名cookieにserver-sideで検証する期限を含めます。defaultは1週間、`HttpOnly`、`Secure`、`SameSite=Lax`です。平文HTTPのlocal開発では`cookie_secure=false`を明示してください。default storeはprocess-local memoryです。login時や権限変更時は`Session.rotate(c)`を呼びます。 |
| `csrf(State, options)` | double-submit cookie方式で、safe methodはGET／HEAD／OPTIONSです。cookieは設計上JavaScriptから読み取れ、defaultで`Secure`です。 |
| `rateLimit(State, options)` | `key_fn`が必須です。defaultは60秒あたり60 requestでheaderを出力します。process／isolate localであり、distributed quotaではありません。 |
| `secureHeaders(State, options)` | API向けのHSTS／CSP／frame／MIME／referrer／permissions headerを設定します。HTML applicationではCSPを調整します。 |
| `compress(State, options)` | 1024 byte以上でgzip、deflateの順に選択します。nativeのbuffered response向けで、Workersとstreaming responseではno-opです。 |
| `etag(State, options)` | 32 byte以上のbuffered 2xx bodyへSHA-256 ETagを付け、必要に応じて304へ変換します。 |
| `serveStatic(State, options)` | `root`が必須で、prefixは`/`、indexは`index.html`です。native専用で、CloudflareではWorkers assetsを使います。 |

本番向けObservability middlewareは、外側から次の順で登録します。

```zig
_ = try app.useAll(am.mw.requestId(State));
_ = try app.useAll(am.mw.accessLogWithOptions(State, .{}));
_ = try app.useAll(am.mw.metrics(State, &counters));
_ = try app.useAll(am.mw.serverTiming(State, .{ .enabled = false }));
```

各middlewareは後から登録した処理を内包します。認証、session、CSRF、rate limitは保護対象handlerより前に置きます。metrics、span、privacyについては[Observability](observability.md)を参照してください。

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
