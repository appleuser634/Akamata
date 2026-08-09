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

Workers固有の挙動:

- D1は`deploy/mobus/worker/index.mjs`のJSPI bridgeへ接続されています。
- outbound HTTPは同じbridgeの`akamata_fetch`実装を使用します。
- Workersは任意のTCP socketを提供しないためMQTTは利用できず、`/api/messages/send`のMQTT publishはskipされます。
- WebSocket sessionは`UserHub` Durable Object経由で配信されます。

## エンドポイント一覧

現在のroute登録は`examples/mobus/src/setup.zig`にあり、handlerは`examples/mobus/src/handlers/`以下へ分割されています。正確なendpoint集合はsource codeを確認してください。以下はroute追加時に陳腐化しにくいよう、機能単位でまとめています。

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
