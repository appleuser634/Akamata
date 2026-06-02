# mobus_server_zig 移植計画 (Workers + Containers 両対応)

`../mobus_server_zig` を Akamata に完全移植し、Cloudflare Workers と Cloudflare Containers の両形態でホストするためのフェーズ別計画。

## 移植スコープ

mobus_server_zig が現状で持っている機能のうち、Akamata で対応する範囲:

| 機能 | Workers | Containers | 備考 |
|---|---|---|---|
| HTTP/1.1 + 26 REST endpoints | ✅ | ✅ | ルーティングは Akamata の `Router(App).build` に書き換え |
| WebSocket ハブ (user_id 単位) | ✅ DO | ✅ in-memory | Workers では Durable Object `UserHub` を 1 ユーザー 1 インスタンスで |
| SQLite (6 テーブル + E2EE prekey) | ✅ D1 | ✅ ファイル | Workers ではエフェメラルディスク不可なので D1 一択 |
| JWT (HS256) 認証 | ✅ | ✅ | Akamata に `auth/jwt.zig` 追加 |
| bcrypt パスワードハッシュ | ✅ | ✅ | Akamata に `auth/bcrypt.zig` 追加 (純 Zig) |
| 環境変数 / .env ローダ | ⚠ Workers `vars`/`secrets` | ✅ .env | Akamata に `env.zig` 追加。Workers では `env.X` を JS 側で props として WASM に注入 |
| OpenWeatherMap REST 呼び出し | ✅ JS `fetch` 経由 | ✅ Zig HTTPS クライアント | Akamata に `http_client.zig` 追加。`backend == .workers` のときは extern fn 経由で JS の `fetch()` を呼ぶ |
| FCM HTTP v1 + Service Account 署名 | ✅ JS `fetch` 経由 | ✅ Zig HTTPS + RS256 | RS256 署名は `std.crypto.sign.rsa` を使う (0.16 で利用可) |
| MQTT パブリッシャー | ⚠ HTTP/WebSocket bridge | ✅ ピュア Zig MQTT QoS0 | Workers では TCP 直叩き不可。HiveMQ Cloud などの **MQTT over WebSocket** に切替えるか、`fetch()` で代替 REST に飛ばす |
| 起動時データロード + Mutex 保護キャッシュ | ✅ DO の constructor | ✅ in-memory | Workers では DO で局所化、Containers ではプロセス起動時 1 回 |

**移植対象から外す候補** (ユーザーに確認):
- CLI client / dashboard バイナリ (サーバ移植が主目的のため後回し)

## アーキテクチャ調整

mobus のオリジナル設計は「単一バイナリ + libmosquitto + libssl + ローカル SQLite」だが、これを **同一ハンドラコードが両環境で動く**ように 3 段抽象化する:

```
ハンドラ (am.Ctx(App)) ───┬─── am.db.Db (SQLite | D1)
                          ├─── am.http_client.Client (Zig TLS | fetch bridge)
                          ├─── am.push.Sender (FCM)
                          ├─── am.mq.Publisher (MQTT direct | webhook bridge)
                          └─── am.env.* (process.Environ | bound vars)
```

- 各抽象は **vtable** (`Db` と同じパターン) で、`backend` で実装差し替え
- Workers モードのとき、外部 I/O は基本的に **JS 側で `await fetch()` → 結果を WASM メモリに書く**
- Containers モードのとき、外部 I/O は **同期 Zig 実装** で完結

## フェーズ計画

### Phase A: 共通ユーティリティ拡張 (フレームワーク)

a1. **`src/env.zig`** — `getEnv(name) ?[]const u8` / `requireEnv(name) ![]const u8` / `loadDotEnv(path)`。Containers では `std.process.Environ`、Workers では `extern fn akamata_env_get(name_ptr, name_len, out_ptr_max)` 経由
a2. **`src/auth/jwt.zig`** — HS256 sign/verify (`std.crypto.auth.hmac.HmacSha256`)、JSON header/payload encode
a3. **`src/auth/bcrypt.zig`** — Blowfish setup + EksBlowfishSetup を純 Zig 実装 (mbedTLS 風の参照実装をベース。`std.crypto.pwhash` には bcrypt 無いので自前)
a4. **`src/crypto/rs256.zig`** — RS256 署名 (`std.crypto.sign.rsa`)。FCM 用
a5. **`src/http_client.zig`** — 抽象 `Client` 型 (vtable: native は Zig TLS、workers は extern fn → JS `fetch`)
a6. **`src/push.zig`** — `Sender.send(notification)` を FCM HTTP v1 にマップ
a7. **`src/mq.zig`** — `Publisher.publish(topic, payload)` を MQTT (native: TCP 直接, workers: webhook 経由) にマップ
a8. **`src/runtime/workers.zig` 拡張** — 上記 extern fn の宣言を追加
a9. **`deploy/worker/index.mjs` 拡張** — JS 側で `akamata_env`, `akamata_fetch`, `akamata_mq_publish` を実装し、`await fetch()` → 同期 step 方式 (D1 と同じ 2-pass コルーチン化)
a10. **D1 ブリッジを本格化** — 現状の「事前 fetched 配列」スタブを「Promise resolve まで Atomics.wait or 2-pass で待つ」設計に切替え

### Phase B: mobus アプリ層移植 (`examples/mobus/`)

b1. **ディレクトリ作成** — `examples/mobus/src/{main.zig, worker.zig, app.zig, routes.zig, handlers/, schema.sql, migrations/}`
b2. **スキーマ** — mobus の migrations 5 ファイルを `examples/mobus/src/schema.sql` に統合
b3. **JWT ミドルウェア** — `Authorization: Bearer <jwt>` を検証、`Ctx.user_id` に注入
b4. **認証ハンドラ** — `/api/auth/{register,login,login-id-available}` (bcrypt + JWT 発行)
b5. **フレンドハンドラ** — `/api/friends/*` 5 endpoints
b6. **メッセージハンドラ** — `/api/messages/*` + `/api/friends/:id/messages/*`
b7. **リアルタイム通話ハンドラ** — `/api/rtchat/*` 5 endpoints + WS シグナリング
b8. **デバイス CRUD** — `/api/devices*`
b9. **天気** — `/api/weather/forecast` (http_client + OpenWeatherMap key)
b10. **疎通** — `/api/ping`, `/api/public/ping`, `/api/user/refresh-friend-code`
b11. **WebSocket ハブ** — native: `UserHub`、Workers: Durable Object `UserHub`
b12. **MQTT 通知 / FCM Push** — メッセージ受信時の trigger

### Phase C: Cloudflare 統合 (`deploy/mobus/`)

c1. **`deploy/mobus/wrangler.toml`** — D1 (`MOBUS_DB`)、Durable Object (`UserHub`)、`secrets` (`JWT_SECRET`, `MQTT_*`, `FCM_*`, `WEATHER_KEY`)、Containers バインディング
c2. **`deploy/mobus/worker/`** — `index.mjs` (JS グルー)、`user_hub.mjs` (DO)、`d1_schema.sql`
c3. **`deploy/mobus/Dockerfile`** — Containers 用静的バイナリ + `linkSystemLibrary("ssl", "crypto")` (MQTT は純 Zig 実装で libmosquitto 依存削除)

### Phase D: テスト・ドキュメント

d1. **テスト追加** — JWT/bcrypt unit tests、env loader、http_client mock
d2. **`docs/mobus-deployment.md`** — D1 マイグレーション手順、`wrangler secret put` 一覧、Containers 起動手順
d3. **CI matrix 拡張** — `examples/mobus` も両ターゲットで build

## 想定工数

| Phase | 内容 | 工数 (一人想定) |
|---|---|---|
| A | フレームワーク拡張 (env/jwt/bcrypt/http_client/push/mq + WASM bridge) | 4-6 日 |
| B | mobus アプリ層 26 endpoints + WS + 通知 | 5-7 日 |
| C | Cloudflare 統合 (wrangler.toml + Worker JS + Dockerfile) | 2-3 日 |
| D | テスト + ドキュメント + CI | 2 日 |
| **合計** | | **13-18 日** |

## 主要リスク

1. **D1 同期化のリエントラント設計** — 現状 D1 ブリッジが「事前 fetched データを返すスタブ」で実装が未完成。本気で動かすには WASM ↔ JS の双方向リエントラントが必要 (Phase A10 が肝)
2. **bcrypt の純 Zig 実装** — リファレンス実装の正しさ検証が必要。互換性テストベクトルが要 (`docs/known-answer-tests.md` を作る)
3. **MQTT のリプレース** — 本番運用で MQTT broker を使い続けるなら、Workers 環境向けに **MQTT over WebSocket** ブローカ (HiveMQ Cloud など) への接続コードが必要。あるいは MQTT を諦めて HTTP webhook + Durable Object に置換するアプリ側の決断
4. **bcrypt の RSA 鍵パース** (FCM 用) — Service Account JSON の PEM 部分を 0.16 の `std.crypto.Certificate.rsa` でパースできるか要確認
5. **TLS クライアント** — `std.crypto.tls.Client` は 0.16 で書き換え中。HTTP/1.1 + TLS のラッパが Akamata 側で必要

## 実装順の推奨

1. Phase A1 (env) + A2 (jwt) — 最小で認証だけ動かす
2. Phase B2 (schema) + B3-B4 (auth) を **Containers で先に**完動させる
3. Phase A5 (http_client) + A6 (push) を Containers で完動させる
4. Phase B 残り (フレンド, メッセージ, ...) を Containers で完動
5. Phase A8-A10 (Workers ブリッジ) — Workers 向けに **B で書いたコードを変更せず**動かす
6. Phase C, D で仕上げ

このやり方なら、各ステップで動作確認ができ、Workers 対応の難所 (D1 リエントラント) を最後に集中して解ける。

## 確定方針 (2026-05-22 合意済み)

1. **MQTT**: Containers のみで純 Zig MQTT QoS0 を実装。Workers では MQTT 関連エンドポイントを 501 で返す
2. **パスワードハッシュ**: bcrypt を純 Zig で実装し mobus 既存データ互換を維持
3. **CLI client / dashboard**: 今回は **サーバのみ移植**。CLI/dashboard は後回し
4. **既存 `mobus_data.db`**: データは破棄しスキーマだけ Akamata に持ってくる (D1 マイグレーション SQL を生成)
5. **E2EE prekey**: mobus のテーブル (`envelopes`, `device_one_time_prekeys`) とエンドポイントをそのまま移植。Expo クライアントとの互換性を保証
