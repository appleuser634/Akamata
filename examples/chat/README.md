# chat 例

Akamata で組んだ最小のチャット API。同じハンドラコードが native (SQLite) と Workers (D1 + Durable Object) の両方で動く。

## ローカル実行

```bash
# プロジェクトルートで
./third_party/sqlite/fetch.sh   # 初回のみ
zig build -Dbackend=native run
```

別ターミナルから:

```bash
curl -X POST localhost:8080/rooms -d '{"name":"general"}' -H content-type:application/json
curl localhost:8080/rooms
curl -X POST localhost:8080/rooms/1/messages -d '{"user":"a","text":"hi"}' -H content-type:application/json
websocat ws://localhost:8080/rooms/1/ws
```

ブラウザで http://localhost:8080/ にアクセスすると最小のチャット UI。

## エンドポイント

| メソッド | パス | 説明 |
|---|---|---|
| GET  | `/`            | HTML クライアント |
| GET  | `/health`      | ヘルスチェック |
| GET  | `/rooms`       | ルーム一覧 |
| POST | `/rooms`       | ルーム作成 `{name}` |
| GET  | `/rooms/:id/messages` | メッセージ取得 |
| POST | `/rooms/:id/messages` | メッセージ送信 `{user,text}` |
| WS   | `/rooms/:id/ws`       | リアルタイムブロードキャスト |
