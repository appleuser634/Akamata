# Quick start

Launch an Akamata web app in 5 minutes.

## 0. Assumptions

-Zig 0.16.0
- (Optional) `npx wrangler` (for Cloudflare Workers deployments)
- (Optional) Docker (for Cloudflare Containers deployments)

## 1. Get the CLI

```bash
git clone <akamata-repo>
cd Akamata
zig build cli
# zig-out/bin/akamata が生成される
```

If you put it in your PATH:

```bash
ln -s "$(pwd)/zig-out/bin/akamata" /usr/local/bin/akamata
```

## 2. Project generation

```bash
akamata init myapp --target=both
cd myapp
```

Directory structure:

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

## 3. Launch natively

```bash
zig build run
# akamata listening on http://0.0.0.0:8080/
```

From another terminal:

```bash
curl localhost:8080/                  # Hello, Akamata!
curl localhost:8080/users/42          # {"id":"42"}
```

## 4. Add route

Edit `src/main.zig`:

```zig
_ = try app.post("/users", createUser);

fn createUser(c: *am.Context(State)) !void {
    const Body = struct { name: []const u8 };
    const body = try c.req.json(Body);
    try c.json(.{ .name = body.name, .created = true }, 201);
}
```

Immediately reflected with `zig build run`.

## 5. Add middleware

```zig
_ = try app.useAll(am.mw.cors(State, .{ .origin = "*" }));
_ = try app.use("/api/*", am.mw.bearerAuth(State, .{ .token = "secret" }));
```

## 6. Deploy to Cloudflare Workers

```bash
# (初回のみ) Cloudflare アカウントにログイン
npx wrangler login

# WASM ビルド + wrangler deploy
akamata deploy --workers
```

If you want to try Workers locally:

```bash
zig build -Dbackend=workers -Doptimize=ReleaseSmall
cd deploy && npx wrangler dev --local
```

## 7. Deploy to Cloudflare Containers

```bash
# 静的バイナリ + Docker image
akamata deploy --containers

# ローカルで Docker 起動
docker run --rm -p 8080:8080 akamata-app
```

## 8. D1 Migration

```bash
akamata db migrations/001_init.sql --remote
```

## Next steps

- Handler API details: [`docs/en/handler-api.md`](handler-api.md)
- WebSocket: [`docs/en/websocket.md`](websocket.md)
- SQLite/D1: [`docs/en/db-backends.md`](db-backends.md)
- Read `examples/chat/` (Simple) and `examples/mobus/` (Full Featured)
