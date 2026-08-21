# Cloudflare デプロイ

Akamata は **Cloudflare Containers** と **Cloudflare Workers (WASM)** の両方で動く。同じハンドラコードを 2 つのビルドターゲットで使い分ける。

## Cloudflare Containers

ネイティブ Linux バイナリをそのままコンテナで実行する。Workers Paid プラン以上が必要。

```bash
zig build -Dbackend=native -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
docker build -f deploy/Dockerfile -t akamata-chat .
wrangler containers build
wrangler deploy
```

注意:
- `linux/amd64` 必須 (arm64 不可)
- ディスクはエフェメラル。SQLite ファイルを永続化したい場合は Durable Objects SQLite か D1 を使う
- `sleepAfter` でスケールゼロ可

## Cloudflare Workers (WASM)

JS薄ラッパーは`-Dexample=...`で選択したWorkers applicationの安定alias
`akamata_worker.wasm`をロードしてリクエストを送り込む。

```bash
zig build -Dbackend=workers -Doptimize=ReleaseSmall
wrangler d1 execute akamata --file=deploy/worker/d1_schema.sql --local   # 初回
wrangler dev --local
```

デプロイ:

```bash
wrangler d1 execute akamata --file=deploy/worker/d1_schema.sql --remote
wrangler deploy
```

### D1

`deploy/wrangler.toml` の `[[d1_databases]]` で `binding = "DB"` を設定。`database_id` を本番の D1 ID に置き換える (`wrangler d1 create akamata` で発行)。

### Durable Object: WebSocket

WS 接続 (`/rooms/:id/ws`) は JS 側で `request.headers.get("Upgrade")` を検知して直接 `CHAT_ROOM` DO にルーティング。DO 内で WS セッションを保持 + DO 内蔵 SQLite に永続化する。Zig 側の WS ハンドラは Workers モードでは呼ばれない。

portable Realtimeでは`/realtime/:resource`を使います。`:resource`は信頼済みroom ID
ではありません。WorkerはAuthorization headerを必須とし、共通Zig handler
`POST /__akamata/realtime/authorize`へ渡します。applicationが認証・参加許可した後に
Principalからroom/logical identityを導出します。client由来`X-Akamata-*` headerは
破棄されます。

Durable Objectは受信messageを自動転送しません。64 KiB、text、JSON envelopeを検査し、
`AKAMATA_REALTIME_HANDLER` service binding経由でapplication handlerを呼びます。
direct/broadcast/sender除外/disconnectの明示actionだけを適用します。

`am.platform.workers.R2Store`はR2 streamとJSPIを使い64 KiB chunkで転送します。
ただし現在のHTTP→WASM bridgeは最初に`request.arrayBuffer()`するためupload全体としては
zero-copyではありません。R2 listとETag/custom metadata完全伝播も残課題です。

## wrangler.toml の要点

```toml
name = "akamata-chat"
main = "worker/index.mjs"
compatibility_date = "2026-01-15"

[[d1_databases]]
binding = "DB"
database_name = "akamata"
database_id = "<your-d1-id>"

[[durable_objects.bindings]]
name = "CHAT_ROOM"
class_name = "ChatRoom"

[[migrations]]
tag = "v1"
new_sqlite_classes = ["ChatRoom"]
```
