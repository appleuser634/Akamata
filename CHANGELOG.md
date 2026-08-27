# Changelog

## [Unreleased]

## [0.1.1] - 2026-08-27

### Fixed

- Serialized all dispatches into a shared Workers WebAssembly instance across
  the complete request/response ABI transaction. Concurrent HTTP requests or
  Queue deliveries can no longer race the JSPI-suspended `handle_fetch`,
  response pointer and length, allocator, or bridge request state.
- Coalesced concurrent first-request WebAssembly initialization and converted
  malformed WASM response status lines into an explicit `502` response instead
  of allowing the Workers `Response` constructor to throw a `RangeError`.

### Testing

- Added a 256-request concurrent Workers regression test that suspends each
  simulated WASM dispatch and verifies response isolation, allocator cleanup,
  FIFO serialization, and recovery after a rejected dispatch.

## [0.1.0] - 2026-08-26

### Added

- Compile-time route graphs, typed request contracts, error-to-response maps,
  capability validation, static middleware composition, static DB dispatch,
  and compile-time DI graph checks.
- Typed, versioned event protocols with TypeScript and bounded C/embedded
  metadata generation.
- Portable realtime contracts with authenticated principals, room
  authorization, presence, direct send, broadcast, sender exclusion, and
  transport-backed disconnect for Native and Durable Objects.
- Portable object storage with filesystem and R2 adapters, metadata, ETags,
  conditional requests, bounded listing, byte ranges, and download helpers.
- Portable Workers bindings and capability declarations for D1, R2, Durable
  Objects, Queues, secrets, and variables.
- Queue delivery metadata, generic identity/principal support, stream and
  outbound-network contracts, and correlated activity observability.
- Contract-aware CLI inspection, project diagnostics, API diffing, resource
  generation, database sandboxing, and a full-screen API client TUI.
- A portable `device_messaging` reference application sharing application
  contracts between Native and Workers targets.

### Changed

- Akamata now supports additive Runtime and Static/comptime API layers over the
  same `App`, `Context`, request, response, OpenAPI, and client-generation core.
- D1 statement buffers, SQLite/Turso migration behavior, native realtime
  fanout, and Workers deployment selection were hardened for production use.
- Realtime messages must pass bounded typed decoding and application handlers;
  the Workers control plane is isolated from public HTTP routes.
- The generated TypeScript realtime client uses the same flat versioned wire
  envelope as the Zig protocol.
- The product-specific Mobus example and all related deployment assets were
  removed.

### Fixed

- Streaming endpoint requests no longer hang the CLI client.
- Native realtime uses per-message allocation and invokes transports outside
  registry locks.
- Ranged downloads use exact content lengths and reject ranges over empty
  representations safely.
- Filesystem object listing uses an iterable directory handle on Linux.
- Native integration shutdown reliably wakes a blocking accept loop on Linux.

### Testing

- Added compile-fail coverage for route, input, error-map, capability, binding,
  protocol, and DI failures.
- Added Native/Workers realtime parity tests, D1 mocks, portable benchmarks,
  storage tests, embedded protocol tests, and opt-in live Cloudflare D1/R2/DO/
  WebSocket coverage.

See the [compile-time architecture](docs/en/comptime-architecture.md),
[portable backend guide](docs/en/portable-backend.md), and
[Japanese documentation](docs/ja/README.md).

## [0.0.2] - 2026-08-17

### Changed

- Route registration is frozen by `App.prepare()`, the first dispatch, or `serve()`; later registration returns `error.RoutesFrozen`.
- Registration rejects duplicate/equivalent routes, ambiguous parameter shapes, duplicate parameter names, non-terminal wildcards, and more than 16 captures.
- `basePath()` returns a lightweight `Group` owned by its parent `App`.
- `HEAD` falls back to `GET` when necessary and suppresses the body. Method mismatches return `405` with a deduplicated `Allow` header.
- Forwarding headers are ignored by default. Enable `ServeOptions.trust_proxy_headers` only behind a trusted proxy.
- Every non-optional input field without a default is required by `c.input(T)`, independently of validation metadata.
- OpenAPI and client route discovery includes routes registered with the untyped helpers; `endpoint()` still attaches reflected schemas.
- Versioned migrations are transactional per file on SQLite and Turso. D1 remains non-transactional.
- The experimental reactor fails closed until it reaches production safety parity.
- Proxy headers require `trust_proxy_headers` and an explicit `trusted_proxy_fn`.
- The unfinished Zig client target returns `error.UnsupportedTarget` instead of generating runtime panics.

### Fixed

- Optional model fields preserve SQL `NULL` instead of mapping it to zero, `false`, or an empty string.
- SQL script execution respects database parsing, quoted semicolons, and comments, and rejects malformed scripts.
- Failed one-time initialization can be retried instead of leaving waiters spinning.
- Default 500 responses no longer expose internal Zig error names.
- Long static paths and trailing-slash matching now agree with indexed routes.
- Built-in session and rate-limiter allocations are released during app teardown.
- Native randomness works on Linux/musl targets.
- HTTPS trust anchors use process-lifetime storage rather than a request arena.
- Stateful middleware is App-local instead of shared by identical factories.
- Outbound HTTP rejects injection, ambiguous framing, and truncated responses.
- Job workers claim atomically and reclaim expired running leases.
- Generated TypeScript clients preserve nullable types, escape path values,
  retain HTTP error bodies, and no longer claim unknown responses are `void`.

### Added

- Explicit `Db.begin()` transactions and bounded `db.Pool` leases.
- OpenAPI operation IDs, status documentation, content types, and security schemes.

### Testing

- CI covers native unit and integration tests, task tests, CLI and example builds, Workers examples, macOS, Docker, and Linux/musl cross-compilation.

See the [English](docs/en/upgrading.md) or [Japanese](docs/ja/upgrading.md) upgrade guide.

## [0.0.1] - 2026-08-10

The initial public release of Akamata.

### Added

- Zig 0.16 web framework core for native servers, Cloudflare Workers, and Containers.
- SQLite, D1, and Turso database backends with model/repository and migration APIs.
- HTTP, WebSocket, SSE, middleware, authentication, CSRF, sessions, and rate limiting.
- Request-scoped observability, database timing, structured logs, Prometheus metrics, and Server-Timing support.
- Akamata CLI, portable project scaffold, migration runner, and deployment workflows.
- Strict HTTP parsing and security hardening for JWT, cookies, uploads, and WebSocket frames.

### Notes

- Requires Zig 0.16.x.
- This is a 0.x initial release; APIs may evolve before 1.0.
