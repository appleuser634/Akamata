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
support direct send, broadcast, broadcast-except-sender, transport close and
presence, including multiple connections per logical identity.

Realtime connections use a strict trust boundary:

1. the gateway extracts credentials and calls the application's authorization handler;
2. the application authenticates a typed Principal and decides whether the requested resource is allowed;
3. application code derives the logical identity and actual room key;
4. only that trusted result is forwarded to the Native registry or Durable Object.

The path component is an authorization input, not a room identifier. Query
parameters and client `X-Akamata-*` headers are never principals. Inbound
messages are bounded, decoded by `events.Protocol`, version checked, and sent
to an application handler. The Durable Object does not automatically relay a
client message. A handler must explicitly return direct/broadcast/
broadcast-except/disconnect effects. Native uses the same decode and handler
contract; `disconnectWithReason` closes the actual transport before cleanup.

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
`storage.filesystem.FileStore` uses positional reads and a 64 KiB transfer
buffer. `platform.workers.R2Store` bridges R2 ReadableStream/WritableStream
through JSPI in 64 KiB chunks. `serveDownload` emits HEAD/200/206/304/412/416,
`Content-Length`, `Content-Range`, `Accept-Ranges` and bounded fixed-length
streaming. Object keys are portable relative keys; absolute paths, empty
segments, backslashes and `..` are rejected before an adapter is called.
`am.net.Connector` is the portable outbound TCP contract and represents TLS
intent without committing to one TLS implementation.

`am.protocol_gen.generate` emits framework-independent TypeScript realtime
unions/envelopes/WebSocket helper or C structs/event metadata. C slices have
explicit pointer/length fields and need no runtime reflection. Integer widths
map predictably to `uint8_t`/`uint16_t`/`uint32_t`/`uint64_t`; fixed bytes are
arrays; bounded strings/slices are inline arrays plus a length; optionals have
an explicit presence flag; the tagged event payload is a C union. The existing
REST TypeScript generator remains compatible.

## Portable embedded reference

`examples/device_messaging/src/application.zig` is shared by both entrypoints.
It demonstrates login/JWT Principal derivation, persistent record creation and
listing, bounded status reports, an authenticated realtime authorization and
inbound handler, object upload, and Range download. Native wires SQLite,
`realtime.Native` and `FileStore`; Workers wires D1, Durable Objects and R2.
Queues are intentionally absent from State: DB commit + optional realtime +
normal HTTP response works without a queue.

Persist durable state before publishing an ephemeral notification. A missed
WebSocket event must be recoverable through REST. Realtime is never the source
of truth for records or delivery state.

## SQLite / D1 portable subset

Use prepared statements, explicit NULLs, stable `ORDER BY`, keyset/limited
pagination, affected rows and insert id through `Db`/`Stmt`. Timestamps in the
reference are signed Unix seconds. SQLite transactions are real connection
transactions. `Db.batch` is ordered fallback execution and is **not** an
atomic D1 transaction; use a D1-supported atomic workflow/DO when atomicity is
required. D1 JavaScript numbers are only exact through 2^53-1, so portable IDs
crossing the JS bridge must stay in that range or be stored as text/blob.
Busy/retry, foreign-key and uniqueness diagnostics are not yet normalized to
one typed error across all three backends. D1 text/blob copies now belong to
the statement and are reclaimed on reset/deinit.

## Native versus Workers and current limits

| Concern | Native | Workers |
|---|---|---|
| HTTP/contracts | `App(State)` | same Zig API |
| SQL | SQLite/Turso | portable `Db` over D1/Turso |
| Realtime | authenticated WS + typed handler | authenticated gateway + hibernation DO |
| Background | SQLite jobs adapter | Queues adapter contract |
| Objects | streaming filesystem adapter | streaming R2 adapter |
| TCP | native connector contract | Workers Socket contract |

The Workers HTTP-to-WASM bridge still buffers the full incoming request before
Zig dispatch, so upload memory is bounded by the application's request limit
but is not zero-copy. R2 `get` propagates ETag/content type/custom metadata and
bounded `list` pages; its legacy `head` path currently returns size only.
Filesystem stores ETag/content/custom metadata in internal sidecars and hides
them from listings. Streaming multipart, complete TCP adapters,
and automated live-WebSocket probing remain follow-up work. The opt-in
`zig build cloudflare-live-test` exercises deployed D1 and R2 only when its
three `AKAMATA_LIVE_*` variables are provided; default CI uses unit/mocks.

## Performance and trade-offs

On an Apple Silicon development host (ReleaseFast, 2026-08-21), typed JSON
event encoding measured 130 ns/op; Native room broadcast measured 145/178/644
ns/op for 1/10/100 callback connections. The previous recorded baseline was
223 ns and 211/256/697 ns respectively. These are framework microbenchmarks,
not WebSocket/network latency. No live Durable Object/R2 result is reported
without Cloudflare credentials. Existing HTTP/router benchmarks remain the
request regression baseline.

The ReleaseSmall `device_messaging` reference grew from 222,816 to 1,257,024
bytes Native and from 32,306 to 178,966 bytes WASM. This is not core-only code
bloat: the old target was a health-only compile proof, while the new target
links JWT, SQL, realtime, storage and streaming handlers. It is nevertheless a
real deployment cost. Applications that do not reference these additive
modules retain Zig's lazy-analysis/dead-code elimination; feature-level size
budgets and deduplication remain future work.

Tagged-union specialization removes runtime schema lookup but increases code
size/build time with the number of event types. VTables remain at platform
boundaries to avoid duplicating large backend implementations. Live D1, R2,
Queues and DO latency must be measured in a real Cloudflare account; local
placeholder resources are not production measurements.
