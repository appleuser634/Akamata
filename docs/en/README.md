# Akamata Documentation

This is the documentation home for Akamata v0.0.2 and Zig 0.16.x. Start with the Quick Start if you are evaluating the framework, then use the Handbook or Tutorial for a deeper walkthrough.

**Release status:** v0.0.2 is the current public 0.x release. The `main` branch
is development-oriented; pin a tagged release for reproducible builds.

[日本語](../ja/README.md) · [Project README](../../README.md)

## Getting started

- [Quick Start](quickstart.md) — install the CLI, generate the current scaffold, and run it
- [Tutorial](tutorial.md) — build an application step by step
- [Handbook](handbook.md) — concise tour of models, repositories, migrations, and deployment
- [Tasks example](example-tasks.md) — guided example application
- [Upgrade guide](upgrading.md) — behavior changes after v0.0.1

## Guides

- [Cloudflare Workers and Containers](cloudflare.md)
- [SQLite, D1, and Turso](db-backends.md)
- [WebSocket](websocket.md)
- [Observability](observability.md)
- [Security](security.md)
- [Release process](releasing.md)

## API reference

- [Handler API](handler-api.md) — `App`, `Context`, request/response helpers, middleware, database, model/repository, HTTP client, authentication, WebSocket, and SSE

## Production and performance

- [Benchmarks](benchmarks.md)
- [Long-run benchmarks](benchmarks-long-run.md)
- [Performance follow-ups](perf-followups.md)
- [Reactor design](perf-reactor-design.md)

Benchmark numbers are snapshots of the recorded environment, commands, and Akamata revision; they are not performance guarantees for another machine or workload.

## Architecture and design history

- [Architecture](architecture.md)
- [v0.2 design record](v0.2-design.md)
- [Historical API redesign record](hono-style-redesign.md)

Design records describe the reasoning at a point in time and may contain superseded examples. Use the [Handler API](handler-api.md) and current source for the supported interface.
