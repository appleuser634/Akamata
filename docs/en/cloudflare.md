# Cloudflare deployment

Akamata works with both **Cloudflare Containers** and **Cloudflare Workers (WASM)**. Use the same handler code between two build targets.

## Cloudflare Containers

Run native Linux binaries as-is in containers. Requires Workers Paid plan or higher.

```bash
zig build -Dbackend=native -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
docker build -f deploy/Dockerfile -t akamata-chat .
wrangler containers build
wrangler deploy
```

Attention:
- `linux/amd64` required (arm64 not possible)
- Discs are ephemeral. If you want to make SQLite files persistent, use Durable Objects SQLite or D1
- Scale zero possible with `sleepAfter`

## Cloudflare Workers (WASM)

JS thin wrapper loads `chat_worker.wasm` and sends the request.

```bash
zig build -Dbackend=workers -Doptimize=ReleaseSmall
wrangler d1 execute akamata --file=deploy/worker/d1_schema.sql --local   # 初回
wrangler dev --local
```

Deploy:

```bash
wrangler d1 execute akamata --file=deploy/worker/d1_schema.sql --remote
wrangler deploy
```

### D1

Set `binding = "DB"` in `[[d1_databases]]` of `deploy/wrangler.toml`. Replace `database_id` with your production D1 ID (issued as `wrangler d1 create akamata`).

### Durable Object: WebSocket

WS connection (`/rooms/:id/ws`) detects `request.headers.get("Upgrade")` on JS side and routes directly to `CHAT_ROOM` DO. Retain WS session within DO + persist to DO built-in SQLite. The Zig side WS handler is not called in Workers mode.

## Main points of wrangler.toml

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
