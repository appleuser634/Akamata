# Akamata

[English](README.md) | 日本語

Zig 0.16 系のミニマル Web フレームワーク。
標準ライブラリのみで HTTP / WebSocket / SQLite を提供し、Cloudflare Workers と Cloudflare Containers の両方にデプロイできる。

```zig
const std = @import("std");
const am = @import("akamata");

const State = struct {};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var app = am.App(State).init(gpa.allocator(), .{});
    defer app.deinit();

    _ = try app.useAll(am.mw.recover(State));
    _ = try app.useAll(am.mw.logger(State));

    _ = try app.get("/", hello);
    _ = try app.get("/users/:id", showUser);

    try app.serve(.{ .port = 8080 });
}

fn hello(c: *am.Context(State)) !void {
    try c.text("Hello, Akamata!");
}

fn showUser(c: *am.Context(State)) !void {
    const id = try c.req.param("id");
    try c.json(.{ .id = id }, 200);
}
```

## クイックスタート

```bash
# 1. CLI をビルド
zig build cli

# 2. 新規プロジェクトを生成
./zig-out/bin/akamata init myapp --target=both
cd myapp

# 3. ネイティブで起動
zig build run

# Cloudflare Workers にデプロイ (要 npx wrangler)
akamata deploy --workers

# Cloudflare Containers にデプロイ (要 docker)
akamata deploy --containers
```

## 📖 ドキュメントから始める

| 目的 | ドキュメント | 所要時間 |
|---|---|---|
| **まず動かしたい** | [クイックスタート](docs/ja/quickstart.md) | 5 分 |
| **15 分で全機能を概観** | [ハンドブック](docs/en/handbook.md) ([日本語](docs/ja/handbook.md) · [PDF](docs/en/handbook.pdf) · [日本語 PDF](docs/ja/handbook.pdf)) | 15 分 |
| **初心者向けに丁寧に学ぶ** | **[詳細チュートリアル (日本語)](docs/ja/tutorial.md)** · [English](docs/en/tutorial.md) · [日本語 PDF](docs/ja/tutorial.pdf) · [English PDF](docs/en/tutorial.pdf) | **60–90 分** |
| **個別トピックを深掘り** | [リファレンス](#リファレンスドキュメント) | — |
| **プレゼン用** | [紹介スライド (日本語 PDF)](docs/ja/slides.pdf) · [English PDF](docs/en/slides.pdf) | 25 枚 |

> 詳細チュートリアルでは、ゼロから **Todo リスト API + HTML UI** を作成し、SQLite から Cloudflare D1 への本番デプロイまで一貫して学べます。Zig を触ったことが無い方も対象です。

## akamata CLI のインストール

`scripts/install.sh` がビルドと `PATH` 配置をまとめて行う。

```bash
# 既定の $HOME/.local/bin にインストール
./scripts/install.sh

# 任意のプレフィックスへ
./scripts/install.sh --prefix=/usr/local
PREFIX=/opt/akamata ./scripts/install.sh

# 最適化レベルの切り替え (既定: ReleaseSafe)
./scripts/install.sh --fast        # ReleaseFast
./scripts/install.sh --small       # ReleaseSmall
./scripts/install.sh --debug       # Debug

# アンインストール
./scripts/install.sh --uninstall

# ヘルプ
./scripts/install.sh --help
```

要件: `zig` 0.16 以降が PATH 上にあること。
インストール後にプレフィックスの `bin` が PATH 上に無い場合はスクリプトが追加方法を案内する。

```bash
# 動作確認
akamata help
akamata init myapp --target=both
```

## 主な機能

| | 説明 |
|---|---|
| **App(State)** | ジェネリック App ビルダー。`app.get("/", h).post(...).use(...)` のチェーン式 |
| **Context(State)** | `c.req.param/query/json(T)`, `c.json/text/html/redirect` |
| **Router** | `/users/:id`, `/files/*rest` などのパスパラメータ |
| **Middleware** | パス単位 (`app.use("/api/*", mw)`) と全体 (`app.useAll`) |
| **basePath** | `app.basePath("/api/v1")` で prefix 付きグループ |
| **ビルトインmw** | `cors`, `bearerAuth`, `jwt`, `logger`, `recover`, `serveStatic` |
| **WebSocket** | HTTP ルートからの upgrade (`am.ws.upgrade(Ctx, c, opts)`) |
| **SQLite / D1** | `am.db` で抽象化、native は sqlite3、Workers は D1 |
| **JWT / bcrypt** | `am.auth.jwt`, `am.auth.bcrypt` (純Zig、$2a$/$2b$ 互換) |
| **HTTPS クライアント** | `am.http_client.send(...)` (OpenSSL リンク) |
| **MQTT QoS0 / FCM Push** | `am.mq.Publisher`, `am.push.Sender` |
| **akamata-cli** | `init / dev / build / deploy / db` の一通り |

## サンプル

| ディレクトリ | 内容 |
|---|---|
| `examples/chat/` | 多人数チャット (REST + WebSocket + SQLite) |
| `examples/turso/` | Turso (libsql Hrana) で動く guestbook API (native 専用) |
| `examples/mobus/` | mobus_server_zig の完全移植 (26 endpoints, JWT, friends, messages, rtchat, devices, weather) |

## リファレンスドキュメント

### 学ぶ・始める

- [📘 詳細チュートリアル (日本語)](docs/ja/tutorial.md) / [English](docs/en/tutorial.md) — Todo アプリをゼロから作る (60–90 分)
- [ハンドブック](docs/en/handbook.md) / [日本語](docs/ja/handbook.md) — 15 分で全機能を概観
- [クイックスタート](docs/ja/quickstart.md) — 5 分で起動まで
- [🎤 紹介スライド (日本語 PDF)](docs/ja/slides.pdf) / [English PDF](docs/en/slides.pdf) — 25 枚、勉強会・社内紹介向け

### リファレンス

- [Architecture](docs/ja/architecture.md) — フレームワーク内部設計
- [Handler API](docs/ja/handler-api.md) — Context / Request / Response の全関数
- [WebSocket](docs/ja/websocket.md) — WS upgrade とハンドラ
- [DB backends](docs/ja/db-backends.md) — SQLite / Turso / D1 と JSPI 仕組み
- [Cloudflare](docs/ja/cloudflare.md) — Workers / Containers デプロイ詳細
- [Hono 風 DX 設計書](docs/ja/hono-style-redesign.md) — API 設計の意図

### 本番運用

- [Observability](docs/ja/observability.md) — Prometheus メトリクスとログ
- [Benchmarks](docs/ja/benchmarks.md) — 短期ベンチ結果
- [Benchmarks (長時間)](docs/ja/benchmarks-long-run.md) — 5 分間 / churn / 低並列の結果
- [Perf follow-ups](docs/ja/perf-followups.md) — 試行と未着手の改善案
- [mobus 移植計画](docs/ja/mobus-portability.md) / [mobus デプロイ](docs/ja/mobus-deployment.md) — 実アプリの移植例

## ライセンス

MIT
