# Akamata

English | [日本語](README.md)

A minimal Zig 0.16 web framework inspired by Hono.
It provides HTTP, WebSocket, and SQLite support using only the standard library,
and deploys to both Cloudflare Workers and Cloudflare Containers.

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

## Quick start

```bash
# 1. Build the CLI
zig build cli

# 2. Create a project
./zig-out/bin/akamata init myapp --target=both
cd myapp

# 3. Run natively
zig build run

# Deploy to Cloudflare Workers (requires npx wrangler)
akamata deploy --workers

# Deploy to Cloudflare Containers (requires Docker)
akamata deploy --containers
```

## 📖 Start with the documentation

| Goal | Document | Time |
|---|---|---|
| **Get running quickly** | [Quick start](docs/en/quickstart.md) | 5 min |
| **Tour all features** | [Handbook](docs/en/handbook.md) ([日本語](docs/ja/handbook.md) · [PDF](docs/en/handbook.pdf) · [日本語 PDF](docs/ja/handbook.pdf)) | 15 min |
| **Learn step by step** | **[Detailed tutorial](docs/en/tutorial.md)** · [日本語](docs/ja/tutorial.md) · [English PDF](docs/en/tutorial.pdf) · [日本語 PDF](docs/ja/tutorial.pdf) | **60–90 min** |
| **Explore a specific topic** | [Reference documentation](#reference-documentation) | — |
| **Present Akamata** | [English slides](docs/en/slides.pdf) · [日本語 PDF](docs/ja/slides.pdf) | 25 slides |

The detailed tutorial builds a complete **Todo list API + HTML UI** from
scratch, then deploys it to production using SQLite and Cloudflare D1. It is
written for readers who are also new to Zig.

## Installing the akamata CLI

`scripts/install.sh` builds the CLI and installs it on your `PATH`.

```bash
# Install to the default $HOME/.local/bin
./scripts/install.sh

# Install under a custom prefix
./scripts/install.sh --prefix=/usr/local
PREFIX=/opt/akamata ./scripts/install.sh

# Select the optimization mode (default: ReleaseSafe)
./scripts/install.sh --fast        # ReleaseFast
./scripts/install.sh --small       # ReleaseSmall
./scripts/install.sh --debug       # Debug

# Uninstall
./scripts/install.sh --uninstall

# Help
./scripts/install.sh --help
```

Requirement: Zig 0.16 or later must be available on `PATH`. If the selected
prefix's `bin` directory is not on `PATH`, the installer explains how to add it.

```bash
# Verify the installation
akamata help
akamata init myapp --target=both
```

## Features

| | Description |
|---|---|
| **App(State)** | Generic App builder with `app.get("/", h).post(...).use(...)` chaining |
| **Context(State)** | `c.req.param/query/json(T)`, `c.json/text/html/redirect` |
| **Router** | Path parameters such as `/users/:id` and `/files/*rest` |
| **Middleware** | Path-scoped (`app.use("/api/*", mw)`) and global (`app.useAll`) middleware |
| **basePath** | Prefix groups with `app.basePath("/api/v1")` |
| **Built-in middleware** | `cors`, `bearerAuth`, `jwt`, `logger`, `recover`, `serveStatic` |
| **WebSocket** | Upgrade from an HTTP route with `am.ws.upgrade(Ctx, c, opts)` |
| **SQLite / D1** | Unified `am.db` abstraction: sqlite3 natively and D1 on Workers |
| **JWT / bcrypt** | Pure Zig `am.auth.jwt` and `$2a$`/`$2b$`-compatible `am.auth.bcrypt` |
| **HTTPS client** | `am.http_client.send(...)` with OpenSSL linking |
| **MQTT QoS0 / FCM Push** | `am.mq.Publisher`, `am.push.Sender` |
| **akamata-cli** | `init`, `dev`, `build`, `deploy`, and `db` workflows |

## Examples

| Directory | Description |
|---|---|
| `examples/chat/` | Multi-user chat with REST, WebSocket, and SQLite |
| `examples/turso/` | Native guestbook API backed by Turso/libsql Hrana |
| `examples/mobus/` | Full mobus_server_zig port with 26 endpoints, JWT, friends, messages, real-time chat, devices, and weather |

## Reference documentation

### Learn and get started

- [📘 Detailed tutorial](docs/en/tutorial.md) / [日本語](docs/ja/tutorial.md) — build a Todo application from scratch (60–90 min)
- [Handbook](docs/en/handbook.md) / [日本語](docs/ja/handbook.md) — tour all features in 15 minutes
- [Quick start](docs/en/quickstart.md) — run your first application in 5 minutes
- [🎤 English slides](docs/en/slides.pdf) / [日本語 PDF](docs/ja/slides.pdf) — 25-slide introduction

### Reference

- [Architecture](docs/en/architecture.md) — framework internals
- [Handler API](docs/en/handler-api.md) — all Context, Request, and Response functions
- [WebSocket](docs/en/websocket.md) — WebSocket upgrades and handlers
- [DB backends](docs/en/db-backends.md) — SQLite, Turso, D1, and JSPI
- [Cloudflare](docs/en/cloudflare.md) — Workers and Containers deployment
- [Hono-style DX design](docs/en/hono-style-redesign.md) — API design rationale

### Production operations

- [Observability](docs/en/observability.md) — Prometheus metrics and logs
- [Benchmarks](docs/en/benchmarks.md) — short benchmark results
- [Long-running benchmarks](docs/en/benchmarks-long-run.md) — five-minute, churn, and low-concurrency results
- [Performance follow-ups](docs/en/perf-followups.md) — experiments and future improvements
- [mobus portability plan](docs/en/mobus-portability.md) / [mobus deployment](docs/en/mobus-deployment.md) — real-world porting example

## License

MIT
