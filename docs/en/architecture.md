# Akamata Architecture

3 layer configuration:

1. **Transport layer** — `src/http/` (HTTP/1.1 synchronous multithreading) and `src/ws/` (WebSocket upgrade). Directly use `std.net.Server` and write based on `std.Io.Reader/Writer`.
2. **Application Layer** — Table-driven routing in `src/router.zig`, `fn(ctx, next) !void` chain in `src/middleware.zig`, per-request arena + typed path parameters in `src/context.zig`.
3. **Persistence layer** — Abstracted with vtables in `src/db/db.zig`. Switch between `src/db/sqlite.zig` (`@cImport("sqlite3.h")`) and `src/db/d1.zig` (extern fn for Workers).

Runtime selection is separated into modules with `src/runtime/native.zig` (TCP listen + SIGINT/SIGTERM) and `src/runtime/workers.zig` (WASM exports `alloc/handle_fetch/dealloc/last_response_length`).

## How to pass app state

`Server(App)` takes `App` as a type parameter and injects `*App` into `Ctx(App)`. The allocator can also use the arena resident in `Ctx`.

```zig
const App = struct { db: am.db.Db, hub: Hub };
var server = try am.Server(App).init(alloc, &app, .{ ... });
```

There is only one handler signature:

```zig
fn handler(ctx: *am.Ctx(App)) !void
```

## Request processing flow (native)

1. Take a connection with `accept()` and run `handleConnection` on the thread pool
2. Continue `recv` until the headers are complete, then `parser.parseRequest` is called.
3. Confirm handler with `router.match`
4. Chain execution with `middleware.run(chain, terminal, ctx)`
5. Send with `res.writeTo(stream)`, loop if `keep-alive`

## WebSocket

`am.ws.upgrade(App, ctx, opts)` calculates `Sec-WebSocket-Accept` and returns 101, and after sending the response, the server hands over the connection to `Conn` and returns control to the handler. `Conn.readMessage(arena)` processes fragments and control frames (ping/pong/close) internally and returns text/binary only.

## Build target

| `-Dbackend` | `-Dtarget` | Application |
|---|---|---|
| `native` | `native` (default) | Local development |
| `native` | `x86_64-linux-musl` | Static binaries for Containers |
| `workers` | `wasm32-freestanding` (Automatic) | Cloudflare Workers WASM |

`build.zig` resolves the target from the flag, so there is no need to specify `-Dtarget` for Workers.

## Production Guidelines

Things to check for production release:

### Network
- **TLS termination**: The framework itself is HTTP only. The standard is to leave HTTPS to the front stage (Cloudflare's WAF / nginx / Caddy). `http_client` outbound TLS is SAN/CN validated + `SSL_VERIFY_PEER`
- **Timeout**: Default for `read_timeout_ms` / `write_timeout_ms` is 30 seconds. For long-term streaming purposes (SSE, etc.), explicitly pass 0.
- **TCP_NODELAY**: Enabled immediately after accept (latency improvement)
- **accept backoff**: 100us→5s exponential backoff in case of transient failure such as EMFILE

### Security
- **HTTP smuggling**: Reject CL + TE coexistence/multiple CLs
- **JWT alg=none attack**: reject anything other than HS256
- **CRLF injection**: `res.header()`, name is HTTP token, value is CR/LF/NUL Reject
- **JSON mass assignment**: Use `am.json.parseLeakyStrict` in trust boundaries such as authentication payload (unknown field rejected)

### MQTT (only for Containers)
- Currently only **plaintext TCP** (`tcp://` / `mqtt://`). non-shipping in TLS-required environments
- MQTT broker authentication is username/password only
- Production Cloudflare Containers must switch to `tls://` or WebSocket over TLS (roadmap)

### Observability
- `am.mw.metrics(State, &counters)` to `useAll` and expose Prometheus format in `GET /metrics`
- Each worker outputs handler error in `std.log.err` structure
- graceful shutdown (listener close → drain) with `SIGINT/SIGTERM`

### D1 in Workers environment
- Implemented with **JSPI** (JavaScript Promise Integration). `new WebAssembly.Suspending(fn)` + `WebAssembly.promising(handle_fetch)` allows Zig handler to call D1 with the same synchronous API as SQLite/Turso
- Runtimes that do not support JSPI, such as the old Miniflare, will fail-closed (`D1Error.BridgeNotImplemented`), so silent failure will not occur.
- For details `docs/en/db-backends.md`
