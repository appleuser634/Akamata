# クイックスタート

5 分で Akamata の Web アプリを起動する。

## 0. 前提

- Zig 0.16.0
- (任意) `npx wrangler` (Cloudflare Workers デプロイ用)
- (任意) Docker (Cloudflare Containers デプロイ用)

## 1. CLI を入手

```bash
git clone <akamata-repo>
cd Akamata
zig build cli
# zig-out/bin/akamata が生成される
```

PATH に通すなら:

```bash
ln -s "$(pwd)/zig-out/bin/akamata" /usr/local/bin/akamata
```

## 2. プロジェクト生成

```bash
akamata init myapp --target=both
cd myapp
```

ディレクトリ構成:

```
myapp/
├── build.zig
├── build.zig.zon
├── README.md
├── .gitignore
├── src/
│   └── main.zig              # Hello World アプリ
└── deploy/
    ├── wrangler.toml         # Cloudflare Workers 設定
    ├── worker/
    │   └── index.mjs         # WASM ロード + HTTP ブリッジ
    └── Dockerfile            # Cloudflare Containers 用
```

## 3. ネイティブで起動

```bash
zig build run
# akamata listening on http://0.0.0.0:8080/
```

別ターミナルから:

```bash
curl localhost:8080/                  # Hello, Akamata!
curl localhost:8080/users/42          # {"id":"42"}
```

## 4. ルートを追加

`src/main.zig` を編集:

```zig
_ = try app.post("/users", createUser);

fn createUser(c: *am.Context(State)) !void {
    const Body = struct { name: []const u8 };
    const body = try c.req.json(Body);
    try c.json(.{ .name = body.name, .created = true }, 201);
}
```

`zig build run` で即反映。

## 5. ミドルウェアを足す

```zig
_ = try app.useAll(am.mw.cors(State, .{ .origin = "*" }));
_ = try app.use("/api/*", am.mw.bearerAuth(State, .{ .token = "secret" }));
```

## 6. Cloudflare Workers にデプロイ

```bash
# (初回のみ) Cloudflare アカウントにログイン
npx wrangler login

# WASM ビルド + wrangler deploy
akamata deploy --workers
```

ローカルで Workers を試す場合:

```bash
zig build -Dbackend=workers -Doptimize=ReleaseSmall
cd deploy && npx wrangler dev --local
```

## 7. Cloudflare Containers にデプロイ

```bash
# 静的バイナリ + Docker image
akamata deploy --containers

# ローカルで Docker 起動
docker run --rm -p 8080:8080 akamata-app
```

## 8. D1 マイグレーション

```bash
akamata db migrations/001_init.sql --remote
```

## 次のステップ

- ハンドラ API の詳細: [`docs/handler-api.md`](handler-api.md)
- WebSocket: [`docs/websocket.md`](websocket.md)
- SQLite / D1: [`docs/db-backends.md`](db-backends.md)
- `examples/chat/` (シンプル) と `examples/mobus/` (フル機能) を読む
