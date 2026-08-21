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

The JS thin wrapper loads `akamata_worker.wasm`, a stable alias produced for
the Workers example selected by `-Dexample=...`, and dispatches the request.

```bash
zig build -Dbackend=workers -Doptimize=ReleaseSmall
wrangler d1 execute akamata --file=deploy/worker/d1_schema.sql --local   # First run
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

For the portable realtime API use `/realtime/:resource`. `:resource` is not a
trusted room id. The Worker requires an `Authorization` header and calls the
shared Zig `POST /__akamata/realtime/authorize` handler. That handler returns a
Principal-derived room/logical identity only after application authorization.
The gateway discards client `X-Akamata-*` headers before forwarding the trusted
context to `AKAMATA_REALTIME`.

Inbound messages are never automatically relayed. The hibernating Durable
Object enforces 64 KiB/text/JSON-envelope bounds and invokes the application
through `AKAMATA_REALTIME_HANDLER`. Only explicit direct/broadcast/
broadcast-except/disconnect actions are applied. Configure the service binding:

```toml
[[services]]
binding = "AKAMATA_REALTIME_HANDLER"
service = "akamata-realtime-handler"
entrypoint = "AkamataRealtimeApplication"
```

Deploy `worker/realtime_handler.mjs` separately with
`wrangler.realtime-handler.toml`, then set `service` to that Worker. Its default
entrypoint always returns 404; only the named Service Binding can reach the
control plane. Do not self-bind the public gateway. Never log Authorization,
source credentials, or payload bodies.

### R2 streaming

`am.platform.workers.R2Store` implements the portable Store using JSPI. The
current generic HTTP-to-WASM bridge calls `request.arrayBuffer()` first and R2
uploads are capped at the application limit, so they are bounded but not
zero-copy. Downloads support byte ranges; the current response ABI reads in
64 KiB chunks but accumulates the final response in WASM memory.
`get` propagates ETag, Content-Type and custom metadata, and `list` returns a
bounded page. The legacy `head` return shape exposes size only on R2; use
`serveDownload`/`get` when conditional metadata is required.

Run the deployed D1/R2 opt-in smoke test with:

```bash
AKAMATA_LIVE_BASE_URL=https://example.workers.dev \
AKAMATA_LIVE_SUBJECT=test-client \
AKAMATA_LIVE_LOGIN_SECRET='...' \
zig build cloudflare-live-test
```

The opt-in test covers D1 write/read, R2 put/Range 206, an authenticated
two-connection Durable Object WebSocket relay, and public-route isolation.
Native WebSocket loops should use `am.realtime.MessageArena` and reset it after
each handled frame so decoded message allocations do not live with the socket.

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
