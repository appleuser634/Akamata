# mobus deployment guide

Steps to deploy a ported implementation of mobus_server_zig to Akamata to both Cloudflare Containers and Workers.

## Build

```bash
# 開発 (macOS / Linux native)
zig build -Dbackend=native -Dexample=mobus

# Containers 用静的バイナリ (Linux musl)
zig build -Dbackend=native -Dexample=mobus \
  -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
# ← OpenSSL が必要なので docker build 経由が確実 (deploy/mobus/Dockerfile)

# Workers WASM
zig build -Dbackend=workers -Dexample=mobus -Doptimize=ReleaseSmall
```

## Environment variables (mobus compatible)

Write to `.env` or set with docker `-e` for Containers or `wrangler secret put` for Workers:

| Variable | Default | Usage |
|---|---|---|
| `JWT_SECRET` | `your-secret-key-here` | JWT HS256 Key |
| `DATABASE_PATH` | `mobus_data.db` | SQLite files (Containers only) |
| `WEATHER_KEY` | `""` | OpenWeatherMap API key |
| `MQTT_BROKER` | `""` | `tcp://host:port` (Containers only) |
| `MQTT_CLIENT_ID` | `akamata-mobus` | |
| `MQTT_USERNAME` | (nullable) | |
| `MQTT_PASSWORD` | (nullable) | |
| `FCM_SERVICE_ACCOUNT_PATH` | (nullable) | Path to Google service account JSON (Containers) |

## Cloudflare Containers (recommended)

```bash
docker build -f deploy/mobus/Dockerfile -t mobus .
docker run --rm -p 8080:8080 \
  -v $PWD/data:/data \
  -e JWT_SECRET=xxx -e WEATHER_KEY=xxx \
  mobus
```

Deploy on Cloudflare:

```bash
cd deploy/mobus
wrangler containers build
wrangler deploy
```

Containers constraints:
- The disk is **ephemeral**. If you want to make SQLite files persistent, bind mount them or replace them with Durable Object SQLite
- scale-to-zero when idle with `sleepAfter`

## Cloudflare Workers

```bash
# 1. D1 データベース作成
wrangler d1 create mobus
# 出てきた database_id を deploy/mobus/wrangler.toml に貼り付け

# 2. スキーマ適用
wrangler d1 execute mobus --file=deploy/mobus/worker/d1_schema.sql --remote

# 3. secrets 設定
echo $JWT_SECRET | wrangler secret put JWT_SECRET
echo $WEATHER_KEY | wrangler secret put WEATHER_KEY

# 4. WASM ビルド + デプロイ
zig build -Dbackend=workers -Dexample=mobus -Doptimize=ReleaseSmall
cd deploy/mobus && wrangler deploy
```

Workers-specific behavior:

- D1 is connected through the JSPI bridge in `deploy/mobus/worker/index.mjs`.
- Outbound HTTP uses the same bridge's `akamata_fetch` implementation.
- MQTT is unavailable because Workers do not provide arbitrary TCP sockets; the MQTT publish in `/api/messages/send` is skipped.
- WebSocket sessions are delivered through the `UserHub` Durable Object.

## Endpoint list

The current route registrations are in `examples/mobus/src/setup.zig`, with handlers split across `examples/mobus/src/handlers/`. Consult those files for the authoritative endpoint set; the summary below is grouped so it does not become stale when individual routes change.

| Method | Path | Authentication |
|---|---|---|
| POST | `/api/auth/register` | ❌ |
| POST | `/api/auth/login` | ❌ |
| GET | `/api/auth/login-id-available?login_id=` | ❌ |
| GET | `/api/public/ping` | ❌ |
| GET | `/api/ping` | ✅ |
| POST | `/api/user/refresh-friend-code` | ✅ |
| POST | `/api/friends/{request,respond}` | ✅ |
| GET | `/api/friends{,/pending,/history,/rejected}` | ✅ |
| POST | `/api/messages/send` | ✅ |
| GET | `/api/messages/unread/count` | ✅ |
| GET | `/api/friends/:id/messages` | ✅ |
| PUT | `/api/messages/:id/read` | ✅ |
| PUT | `/api/friends/:id/messages/read-all` | ✅ |
| POST | `/api/rtchat/call{,/respond,/end,/signal}` | ✅ |
| GET | `/api/rtchat/call/status` | ✅ |
| {POST,GET,PUT,DELETE} | `/api/devices[/:id]` | ✅ |
| POST | `/api/weather/forecast` | ✅ |
| WS | `/api/ws` | ✅ |
