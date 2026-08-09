# Akamata

[English](README.md) | 日本語

Zig 0.16向けのミニマルWebフレームワークです。Zigと標準ライブラリを中心に
HTTP/WebSocket層を構成し、SQLite、D1、TursoのDBバックエンドと、native server、
Cloudflare Workers、Cloudflare Containersへのデプロイをサポートします。

```zig
const std = @import("std");
const am = @import("akamata");

const State = struct {};

fn hello(c: *am.Context(State)) !void {
    try c.text("Hello, Akamata!");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var app = am.App(State).init(gpa.allocator(), .{});
    defer app.deinit();
    _ = try app.get("/", hello);
    try app.serve(.{ .port = 8080 });
}
```

## Why Akamata?

- **1つのコードベース、複数のruntime** — handlerをnative server、Workers、
  Containersで共有できます。runtime固有のentry pointは明示的に分離されます。
- **統一DB API** — ローカルSQLite、Cloudflare D1、Tursoで同じ`Db`/`Stmt`と
  model repository APIを利用できます。
- **Zigらしい開発体験** — 型付きの`App(State)`、`Context(State)`、入力検証、
  middleware、model schema、repositoryを提供します。
- **本番向けobservability** — request、DB、outbound HTTP、独自spanの時間を、
  Prometheus metrics、structured log、`Server-Timing`から確認できます。

## クイックスタート

CLI installerはリポジトリに含まれるため、最初にcloneします。

```bash
git clone https://github.com/appleuser634/Akamata.git
cd Akamata
./scripts/install.sh

# $HOME/.local/binへPATHを通した後、任意のdirectoryで生成できます。
cd ~/projects
akamata init myapp --target=both
cd myapp
zig build run
```

別のterminalから確認します。

```bash
curl -sS http://127.0.0.1:8080/
curl -sS http://127.0.0.1:8080/notes
```

生成projectには、validation付き`Note` model、SQLite自動migration、`/notes` CRUD、
health route、空のversion付きmigration directory、Workers entry point、Wrangler設定、Workers JS glue、Container用Dockerfileが
含まれます。正確なtreeとresponseは[クイックスタート](docs/ja/quickstart.md)を参照してください。

CLI自体を開発する場合は、installせず直接buildできます。

```bash
zig build cli
./zig-out/bin/akamata help
```

## 要件と対応環境

| 対象 | 要件 |
|---|---|
| 基本開発環境 | Zig 0.16.x、macOSまたはLinux、libc |
| native DB | 同梱SQLite amalgamation。system SQLiteのinstallは不要 |
| Workers | Node.js、Wrangler、Cloudflare account。D1は任意 |
| Containers | Docker。Cloudflare Containersには対応planが必要 |
| Turso / HTTPS client | Zig標準ライブラリのTLSとOS trust store |
| FCM RS256署名のみ | OpenSSL build flag (`-Dopenssl=true`)が任意で必要 |

Windows nativeはdocument/test対象外です。対応済みのLinux workflowにはWSL2を使用してください。
SSEとnative WebSocket connectionは現在nativeのみです。WorkersのWebSocketは、提供される
Workers/Durable Object integration patternを使用します。

## ドキュメント

| 目的 | 日本語 | English |
|---|---|---|
| まず動かす | [クイックスタート](docs/ja/quickstart.md) | [Quick Start](docs/en/quickstart.md) |
| 順番に学ぶ | [チュートリアル](docs/ja/tutorial.md) | [Tutorial](docs/en/tutorial.md) |
| 全体を把握する | [ハンドブック](docs/ja/handbook.md) | [Handbook](docs/en/handbook.md) |
| 目的別に探す | [ドキュメントホーム](docs/ja/README.md) | [Documentation home](docs/en/README.md) |
| Akamataを紹介する | [スライド (PDF)](docs/ja/slides.pdf) | [Slides (PDF)](docs/en/slides.pdf) |

## 主な機能

- runtime route builder、path parameter、route group、middleware
- JSON、form、multipart、cookie、validation、型付きmodel repository
- SQLite、JSPI経由のD1、Turso/libsql Hrana
- native WebSocket、SSE、static file、compression、security middleware
- JWT、bcrypt、session、CSRF、rate limit、bearer authentication
- native/Workers outbound HTTP、MQTT QoS 0、任意のFCM support
- request ID、access log、Prometheus metrics、軽量span、`Server-Timing`
- OpenAPI生成、typed client生成、testing client、job、cron

backend対応状況とAPI詳細は、[Handler API](docs/ja/handler-api.md)、
[DBバックエンド](docs/ja/db-backends.md)、[WebSocketガイド](docs/ja/websocket.md)を参照してください。

## Examples

- [`examples/chat/`](examples/chat/) — SQLiteを使うREST + native WebSocket chat
- [`examples/guestbook/`](examples/guestbook/) — SQLite、D1、Turso向けmodel/repository guestbook
- [`examples/tasks/`](examples/tasks/) — validation、OpenAPI、SSE、session、security middleware、
  job、testを扱うreference REST API
- [`examples/mobus/`](examples/mobus/) — 大規模な実アプリの移植例
- [`examples/bench/`](examples/bench/) — 再現可能なframework benchmark

## ライセンス

MIT
