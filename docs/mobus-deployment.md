# mobus デプロイガイド

mobus_server_zig を Akamata に移植した実装を Cloudflare Containers と Workers の両方にデプロイする手順。

## ビルド

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

## 環境変数 (mobus 互換)

`.env` に書くか、Containers なら docker `-e`、Workers なら `wrangler secret put` で設定:

| 変数 | デフォルト | 用途 |
|---|---|---|
| `JWT_SECRET` | `your-secret-key-here` | JWT HS256 鍵 |
| `DATABASE_PATH` | `mobus_data.db` | SQLite ファイル (Containers のみ) |
| `WEATHER_KEY` | `""` | OpenWeatherMap API key |
| `MQTT_BROKER` | `""` | `tcp://host:port` (Containers のみ) |
| `MQTT_CLIENT_ID` | `akamata-mobus` | |
| `MQTT_USERNAME` | (nullable) | |
| `MQTT_PASSWORD` | (nullable) | |
| `FCM_SERVICE_ACCOUNT_PATH` | (nullable) | Google service account JSON へのパス (Containers) |

## Cloudflare Containers (推奨)

```bash
docker build -f deploy/mobus/Dockerfile -t mobus .
docker run --rm -p 8080:8080 \
  -v $PWD/data:/data \
  -e JWT_SECRET=xxx -e WEATHER_KEY=xxx \
  mobus
```

Cloudflare 上にデプロイ:

```bash
cd deploy/mobus
wrangler containers build
wrangler deploy
```

Containers の制約:
- ディスクは**エフェメラル**。SQLite ファイルを永続化したい場合はバインドマウントするか、Durable Object SQLite に置き換える
- `sleepAfter` でアイドル時に scale-to-zero

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

Workers の制約 (Phase A10 で完全解消予定):
- **D1 同期化 (リエントラント)** が MVP では未完成。`d1_*` extern は -1 を返しスタブ状態。D1 を実際に使うハンドラは現状 502 を返す
- **外部 HTTP (`http_client.send`)** も同様に未配線。`/api/weather/forecast` は 502 になる
- **MQTT は使えない** (TCP直接アクセス不可)。`/api/messages/send` の MQTT publish はスキップされる
- WebSocket は `UserHub` Durable Object 経由で配信

## エンドポイント一覧

`mobus_server_zig` 互換 26 endpoints。詳細は `examples/mobus/src/routes.zig`。

| メソッド | パス | 認証 |
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
