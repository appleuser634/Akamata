# Akamata アーキテクチャ

3 層構成:

1. **Transport 層** — `src/http/` (HTTP/1.1 同期マルチスレッド) と `src/ws/` (WebSocket upgrade)。`std.net.Server` を直接使い、`std.Io.Reader/Writer` をベースに書く。
2. **Application 層** — `src/router.zig` でテーブル駆動ルーティング、`src/middleware.zig` で `fn(ctx, next) !void` チェーン、`src/context.zig` で per-request arena + 型付きパスパラメータ。
3. **Persistence 層** — `src/db/db.zig` の vtable で抽象。`src/db/sqlite.zig` (`@cImport("sqlite3.h")`) と `src/db/d1.zig` (Workers 用 extern fn) を切替。

ランタイム選択は `src/runtime/native.zig` (TCP listen + SIGINT/SIGTERM) と `src/runtime/workers.zig` (WASM exports `alloc/handle_fetch/dealloc/last_response_length`) でモジュール単位に分離。

## アプリ状態の渡し方

`Server(App)` は `App` を型パラメータで取り、`*App` を `Ctx(App)` に注入する。アロケータも `Ctx` に常駐する arena が利用できる。

```zig
const App = struct { db: am.db.Db, hub: Hub };
var server = try am.Server(App).init(alloc, &app, .{ ... });
```

ハンドラのシグネチャは **1 種類だけ**:

```zig
fn handler(ctx: *am.Ctx(App)) !void
```

## リクエスト処理フロー (native)

1. `accept()` でコネクションを取り、スレッドプール上で `handleConnection` が動く
2. ヘッダが揃うまで `recv` を続け、`parser.parseRequest` が呼ばれる
3. `router.match` でハンドラ確定
4. `middleware.run(chain, terminal, ctx)` でチェーン実行
5. `res.writeTo(stream)` で送信、`keep-alive` ならループ

## WebSocket

`am.ws.upgrade(App, ctx, opts)` は `Sec-WebSocket-Accept` を計算して 101 を返し、サーバはレスポンス送信後コネクションを `Conn` に引き渡してハンドラに制御を戻す。`Conn.readMessage(arena)` がフラグメントと制御フレーム (ping/pong/close) を内部で処理し、テキスト/バイナリのみを返す。

## ビルドターゲット

| `-Dbackend` | `-Dtarget` | 用途 |
|---|---|---|
| `native` | `native` (default) | ローカル開発 |
| `native` | `x86_64-linux-musl` | Containers 用静的バイナリ |
| `workers` | `wasm32-freestanding` (自動) | Cloudflare Workers WASM |

`build.zig` がフラグから target を解決するので、Workers 時は `-Dtarget` を指定する必要はない。

## Production ガイドライン

Production リリースに向けて確認すべき項目:

### ネットワーク
- **TLS 終端**: フレームワーク自体は HTTP のみ。HTTPS は前段 (Cloudflare の WAF / nginx / Caddy) に任せるのが標準。`http_client` の outbound TLS は SAN/CN 検証 + `SSL_VERIFY_PEER` 済み
- **タイムアウト**: `read_timeout_ms` / `write_timeout_ms` のデフォルトは 30 秒。長時間 streaming する用途 (SSE 等) では明示的に 0 を渡す
- **TCP_NODELAY**: accept 直後に有効化済み (latency 改善)
- **accept backoff**: EMFILE 等の transient failure で 100us→5s 指数バックオフ

### セキュリティ
- **HTTP smuggling**: CL + TE 同居・複数 CL を拒否
- **JWT alg=none 攻撃**: HS256 以外を拒否
- **CRLF injection**: `res.header()` で name は HTTP token、value は CR/LF/NUL 拒否
- **JSON mass assignment**: 認証 payload など信頼境界では `am.json.parseLeakyStrict` を使う (unknown field 拒否)

### MQTT (Containers 専用)
- 現状は **平文 TCP のみ** (`tcp://` / `mqtt://`)。TLS 必須環境では non-shipping
- MQTT broker 認証は username/password のみ
- 本番の Cloudflare Containers では `tls://` か WebSocket over TLS への切り替えが必要 (roadmap)

### 観測性
- `am.mw.metrics(State, &counters)` を `useAll` し、`GET /metrics` で Prometheus 形式 expose
- 各 worker は handler error を `std.log.err` で構造化出力
- `SIGINT/SIGTERM` で graceful shutdown (listener close → drain)

### Workers 環境での D1
- **JSPI** (JavaScript Promise Integration) で実装済み。`new WebAssembly.Suspending(fn)` + `WebAssembly.promising(handle_fetch)` により、Zig ハンドラは SQLite/Turso と同じ同期 API で D1 を呼べる
- 旧 Miniflare など JSPI 未対応ランタイムでは fail-closed (`D1Error.BridgeNotImplemented`) になるので silent failure はしない
- 詳細は `docs/db-backends.md`
