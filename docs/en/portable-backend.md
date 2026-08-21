# Portable Backend and Realtime Architecture

Akamata uses Zig types as the contract shared by HTTP, persistent events,
realtime transports and generated clients. Platform services stay behind
small application-facing interfaces; Cloudflare bindings do not leak into
application code.

## Typed contracts and events

`am.events.Descriptor(T, options)` accepts a struct, enum or tagged union and
derives its name, version, stable type id and JSON serializer.
`am.events.Protocol(U, v)` requires a tagged union and emits a versioned JSON
envelope with event type, optional event/correlation ids and payload. Unknown
events should be ignored or rejected without closing the connection; unknown
JSON fields are ignored for additive evolution. Breaking changes require a new
protocol version.

`FixedBytes(N)`, `BoundedString(N)` and `BoundedSlice(T,N)` share size limits
with runtime validation, OpenAPI and embedded metadata without heap allocation.

## Persistent delivery versus realtime

`am.queue.Producer` is the persistent, at-least-once path. Delivery metadata
contains an event id, attempt, retry limit, optional idempotency key,
correlation id and failure information. Consumers must be idempotent; Akamata
does not promise exactly-once delivery. Native adapters can use `am.jobs` and
Workers adapters use Cloudflare Queues.

`am.realtime.Service` is the ephemeral, session-oriented path. Typed rooms
support direct send, broadcast, disconnect and presence, including multiple
connections per logical identity. `am.realtime.Native` accepts the existing
WebSocket connection's send callback. Workers route `/realtime/:room` to the
generic `AkamataRealtimeRoom` Durable Object. It uses the hibernation API,
WebSocket attachments and per-room SQLite state.

## Identity, bindings and capabilities

`am.identity.Credential` models bearer, API token, shared secret and custom
header credentials. `Context.setPrincipal`/`principal(T)` attaches any typed
account, client/device or service principal without changing existing JWT APIs.

Declare D1, R2, Durable Objects, Queues, Secrets and vars using `am.binding.*`.
`am.binding.validate(Env, .workers)` catches duplicate declarations and target
incompatibility at compile time. Wrangler remains the deployment source of
truth; run `wrangler types` to verify actual binding names.

Capabilities include `outbound_tcp`, `r2`, `queues`, `web_crypto` and
`persistent_storage`. Secrets require intentional reveal. Payloads and
credentials are absent from `observability.Activity`; it contains only ids,
attempt, room/session, transport, backend, duration and normalized error.

## Storage, streaming, TCP and clients

`am.storage.Store` defines put/get/delete/head/list, metadata, byte ranges and
conditional operations. Bodies use bounded pull-based `am.stream.Reader` and
`Writer`, making buffering and backpressure explicit. `parseRange` and
`evaluate` share HTTP Range/ETag logic between filesystem and R2 adapters.
`am.net.Connector` is the portable outbound TCP contract and represents TLS
intent without committing to one TLS implementation.

`am.protocol_gen.generate` emits framework-independent TypeScript realtime
unions/envelopes/WebSocket helper or C structs/event metadata. C slices have
explicit pointer/length fields and need no runtime reflection. The existing
REST TypeScript generator remains compatible.

## Native versus Workers and current limits

| Concern | Native | Workers |
|---|---|---|
| HTTP/contracts | `App(State)` | same Zig API |
| SQL | SQLite/Turso | portable `Db` over D1/Turso |
| Realtime | Native adapter + current WS | hibernation-compatible DO |
| Background | SQLite jobs adapter | Queues adapter contract |
| Objects | filesystem adapter contract | R2 adapter contract |
| TCP | native connector contract | Workers Socket contract |

The interfaces are stable, but some platform adapters are contract-complete
rather than end-to-end production-complete. The Workers HTTP-to-WASM bridge
still buffers the full request body; true zero-copy request streaming,
streaming multipart, complete R2/Queue/TCP host bridges and live Cloudflare
integration tests remain follow-up work. `examples/device_messaging` verifies
that one application contract compiles for Native and Workers.

## Performance and trade-offs

On an Apple Silicon development host (ReleaseFast, 2026-08-21), typed JSON
event encoding measured 223 ns/op; room broadcast measured 211/256/697 ns/op
for 1/10/100 connections. These are framework microbenchmarks, not network
throughput. Existing HTTP/router benchmarks remain the request regression
baseline.

Tagged-union specialization removes runtime schema lookup but increases code
size/build time with the number of event types. VTables remain at platform
boundaries to avoid duplicating large backend implementations. Live D1, R2,
Queues and DO latency must be measured in a real Cloudflare account; local
placeholder resources are not production measurements.
