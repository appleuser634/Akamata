# examples/tasks

Akamata の代表的な機能を 1 アプリにまとめたタスク管理 REST API です。新しいアプリを書き始めるときの叩き台、または「あの機能、どう書くんだっけ?」を探すためのリファレンスとして使ってください。

詳しい解説は [`docs/example-tasks.md`](../../docs/example-tasks.md) を参照してください。

## クイックスタート

```sh
# サーバ起動 (SQLite ファイル: ./tasks.db, ポート 8080)
zig build -Dexample=tasks
./zig-out/bin/tasks

# テスト
zig build tasks-test
```

## 動かしてみる

```sh
# 作成 (バリデーション通過 → 201)
curl -X POST -H 'content-type: application/json' \
     -d '{"title":"buy milk","description":"2L"}' \
     http://localhost:8080/tasks

# 一覧 + ETag
curl -i http://localhost:8080/tasks
curl -i -H 'if-none-match: "<paste-etag-here>"' http://localhost:8080/tasks  # → 304

# バリデーションエラー
curl -X POST -H 'content-type: application/json' -d '{"title":""}' \
     http://localhost:8080/tasks   # → 422

# SSE
curl -N http://localhost:8080/events

# 自動生成された仕様 / クライアント
curl http://localhost:8080/openapi.json
curl http://localhost:8080/client.ts
```

## このサンプルで学べること

- Model (`src/models.zig`) — 構造体 = DB スキーマ + バリデーション
- ミドルウェアスタック (`src/setup.zig`) — recover / logger / requestId / cors / secureHeaders / compress / etag
- バリデーション付き入力パース (`src/handlers.zig`) — `c.input(T)` で 400/422 を自動化
- SSE ストリーミング (`src/handlers.zig` の `streamEvents`)
- 永続ジョブキュー (`src/handlers.zig` の `notifyJob`)
- OpenAPI 3.1 と TS クライアントの自動生成
- `am.testing.Client` を使った E2E テスト (`src/integration_test.zig`)
