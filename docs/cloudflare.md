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

JS 薄ラッパーが `chat_worker.wasm` をロードしてリクエストを送り込む。

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
