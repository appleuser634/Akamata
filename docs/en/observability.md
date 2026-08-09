# Observability

Akamata measures request, database, outbound HTTP, and application-defined
timings with one monotonic clock and a request-scoped, allocation-free trace.
It is deliberately smaller than OpenTelemetry: the data can be exposed as
Prometheus metrics, JSON logs, or `Server-Timing` without putting SQL, raw URLs,
or unbounded user values into labels.

## Quick start

```zig
var counters: am.mw.MetricsCounters = .{};

_ = try app.useAll(am.mw.requestId(State));
_ = try app.useAll(am.mw.accessLogWithOptions(State, .{
    .format = .json,
    .include_raw_path = false,
}));
_ = try app.useAll(am.mw.metricsWithConfig(State, &counters, .{
    .latency_profile = .web,
}));
_ = try app.useAll(am.mw.serverTiming(State, .{ .enabled = false }));
_ = try app.get("/metrics", am.mw.metricsHandler(State, &counters));
```

The existing `requestId`, `accessLog`, `metrics`, and `metricsHandler` APIs are
still available. `metrics` now defaults to the `.web` histogram profile.

Middleware order matters: request ID and access log should wrap metrics and
the application. `Server-Timing` must wrap the code whose spans it should emit.

## Request context

Every `Context` embeds `TraceContext`; it has the same lifetime as the request
and does not allocate. It is separate from `c.user_data`, which remains for
sessions, JWT claims, and application middleware.

```zig
const request_id = c.requestId();       // ?[]const u8
const route = c.routePattern();         // e.g. /api/news/:id
```

The router writes only the registered route template. Raw dynamic paths are
never used as metric labels. `requestId` accepts a printable inbound
`X-Request-ID` up to 64 bytes or generates UUIDv4, stores it in the dedicated
trace field, and echoes it in the response.

## Lightweight spans

```zig
fn create(c: *Ctx) !void {
    var title = c.startSpan("r2.title.put");
    defer title.end();
    try putTitleImage(...);
}
```

`defer` closes the span on success and error. Spans nest, retain their parent
index, and use a fixed 24-entry request buffer. Excess spans are counted as
dropped; there is no request HashMap or heap allocation. Prefer comptime/static
names. Never construct names from IDs, SQL, URLs, usernames, or other input.

The following prefixes also feed safe request aggregates:

- `r2.` / `storage.` → storage duration and operation count
- `http.` / `fetch.` → outbound HTTP aggregates when used as manual spans
- `db.`, `serialize`, `framework`, `middleware` → classified span records

Use `c.fetch(request)` for automatically instrumented outbound HTTP. It records
count, duration, and errors without retaining the URL. Direct
`am.http_client.send` remains uninstrumented for compatibility.

## Database instrumentation

Use `c.db()` in handlers and pass that value into model/query functions:

```zig
var stmt = try c.db().prepare("SELECT id, title FROM news");
defer stmt.deinit();
while ((try stmt.step()) == .row) { ... }
```

`c.db()` returns a lightweight copy of `Db` bound to this request trace; it does
not mutate the shared database handle. Instrumentation is centralized in the
`Db`/`Stmt` vtable facade:

- `exec()` is timed once as `exec`.
- A prepared statement is timed/count once at its first `step()`.
- Further row steps do not increment the count.
- `reset()` starts a new execution lifecycle.
- Errors increment the fixed backend error counter.

Backends are the fixed set `sqlite`, `d1`, `turso`, `other`. For D1 the first
step contains the single `d1_run()` JSPI suspend, so its duration is precisely
the D1 bind/raw await plus bridge overhead—not `prepare()` and not every row.
SQLite measures its first `sqlite3_step`; Turso measures the Hrana HTTP pipeline
wait. SQL text is never exported or logged by default.

Calling `c.state().db` bypasses request instrumentation; this is retained for
source compatibility and for initialization/migration code outside a request.

## Metrics

Request series retained for compatibility:

- `akamata_requests_total`
- `akamata_requests_in_flight`
- `akamata_requests_by_status{class}`
- `akamata_requests_by_method{method}`
- `akamata_request_latency_seconds` histogram/count/sum
- native process RSS, first-observation time, and uptime

New fixed-cardinality series:

- `akamata_request_errors_total{class="handler"}`
- `akamata_db_operations_total{backend}`
- `akamata_db_operation_duration_seconds{backend}`
- `akamata_db_errors_total{backend}`
- `akamata_outbound_http_requests_total`
- `akamata_outbound_http_errors_total`
- `akamata_outbound_http_duration_seconds`

`.web` boundaries are 10, 25, 50, 100, 250, 500 ms, 1, 2.5, and 5 s.
`.fast` preserves the earlier 100 µs through 100 ms profile:

```zig
am.mw.metricsWithConfig(State, &counters, .{ .latency_profile = .fast })
```

Process RSS is reported as zero on Workers because there is no meaningful
process RSS. Worker isolate counters reset at cold start and may be split among
isolates, so `/metrics` is a diagnostic endpoint—not a durable global counter.
Use structured logs, Cloudflare Workers Analytics, or a future exporter for
fleet-wide production data.

## Server-Timing

This is opt-in because it reveals internal component names to clients:

```zig
_ = try app.useAll(am.mw.serverTiming(State, .{
    .enabled = true,
    .include_named_spans = true,
}));
```

Example: `Server-Timing: db;dur=38.700, storage;dur=154.600,
r2.title.put;dur=71.200`. Names must contain only ASCII letters, digits,
`.`, `_`, or `-`, and are capped at 48 bytes. No SQL or attributes are emitted.
Disable named spans or the entire middleware in public production responses.

## Structured access log

`accessLogWithOptions` emits compact request aggregates:

```json
{"request_id":"…","method":"GET","path":"-","route":"/api/news/:id","status":200,"duration_ms":42.100,"db":{"queries":1,"execs":0,"errors":0,"duration_ms":37.800},"outbound_http":{"requests":0,"duration_ms":0.000},"storage":{"operations":0,"duration_ms":0.000}}
```

Set `include_raw_path = false` when paths may contain email addresses, tokens,
search terms, or other PII. Akamata never logs authorization headers, bodies,
SQL, bind values, or full outbound URLs. Request IDs are suitable for joining a
request log to an application error log; errors themselves remain bounded
metrics (`handler`, backend) rather than stack/error strings as labels.

## Native and Workers clocks

Wall timestamps and durations are separate. Native durations use
`clock_gettime(CLOCK_MONOTONIC)`; Workers import `akamata_monotonic_ns`, backed
by `performance.now() * 1_000_000`. JSON timestamps use realtime/`Date.now()`
only as wall time. `Date.now()` is never used for a duration. This makes short
Workers requests and JSPI suspension visible at micro/millisecond resolution.

## Production patterns

For `GET /api/news`, query through `c.db()` and the log/Server-Timing will show
request total versus D1 total. For image creation, wrap each R2 operation with
stable names such as `r2.title.put` and `r2.main.put`; storage total and each
named span then appear without adding an R2-specific framework dependency.
Wrap migrations with `db.migrate` to distinguish cold initialization work.

Streaming duration currently means middleware/handler completion, not the time
until a client consumes the final byte. WebSocket duration means upgrade
request completion, not socket lifetime.

## Cardinality and future exporters

Only fixed enums and registered route templates are suitable metric labels.
Never label with raw paths, SQL, URLs, error text, request IDs, or arbitrary
span names. Span records already preserve name, parent, and duration in a small
request structure; trace/span IDs and an `Observer.onRequestEnd/onDbEnd` hook
can be added later for OTLP or Analytics Engine without changing handler span
usage. A complete OpenTelemetry SDK/OTLP exporter is intentionally out of scope.
