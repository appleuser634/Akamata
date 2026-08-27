# Akamata Documentation

This is the documentation home for Akamata v0.1.2 and Zig 0.16.x. Start with the Quick Start if you are evaluating the framework, then use the Handbook or Tutorial for a deeper walkthrough.

**Release status:** v0.1.2 is the current public 0.x release. The `main` branch
is development-oriented; pin a tagged release for reproducible builds.

[日本語](../ja/README.md) · [Project README](../../README.md)

## Getting started

- [Quick Start](quickstart.md) — install the CLI, generate the current scaffold, and run it
- [Tutorial](tutorial.md) — build an application step by step
- [Handbook](handbook.md) — concise tour of models, repositories, migrations, and deployment
- [Tasks example](example-tasks.md) — guided example application
- [Upgrade guide](upgrading.md) — behavior changes after v0.0.1
- [Developer experience](developer-experience.md) — contracts, typed inputs/DI, project inspection, generators, API diff, and migration workflow
- [CLI API client](cli-client.md) — direct and OpenAPI operation-based requests from `akamata`

## Guides

- [Portable Backend and Realtime Architecture](portable-backend.md)

- [Cloudflare Workers and Containers](cloudflare.md)
- [SQLite, D1, and Turso](db-backends.md)
- [WebSocket](websocket.md)
- [Observability](observability.md)
- [Security](security.md)
- [Release process](releasing.md)

## API reference

- [Handler API](handler-api.md) — `App`, `Context`, request/response helpers, middleware, database, model/repository, HTTP client, authentication, WebSocket, and SSE

## Production and performance

- [2026-08-17 performance regression report](benchmarks-2026-08-17.md) — same-machine A/B of the current revision and its pre-change baseline
- [Benchmarks](benchmarks.md)
- [Long-run benchmarks](benchmarks-long-run.md)
- [Performance follow-ups](perf-followups.md)
- [Reactor design](perf-reactor-design.md)

Benchmark numbers are snapshots of the recorded environment, commands, and Akamata revision; they are not performance guarantees for another machine or workload.

## Architecture and design history

- [Compile-time architecture](comptime-architecture.md) — static route graphs, typed contracts, capabilities, DI, and specialization trade-offs
- [Compile-time routing benchmark](comptime-benchmarks-2026-08-17.md) — route/middleware scaling and artifact-size comparison
- [Architecture](architecture.md)
- [v0.2 design record](v0.2-design.md)
- [Historical API redesign record](hono-style-redesign.md)

Design records describe the reasoning at a point in time and may contain superseded examples. Use the [Handler API](handler-api.md) and current source for the supported interface.
