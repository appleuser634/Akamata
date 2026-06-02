# Observability

This page is for operators running Akamata in production. It covers
metrics, structured access logs, and request IDs.

---

## Quick wiring

Add to your `registerRoutes`:

```zig
var metrics_counters: am.MetricsCounters = .{};

pub fn registerRoutes(app: *am.App(State)) !void {
    _ = try app.useAll(am.mw.recover(State));
    _ = try app.useAll(am.mw.requestId(State));               // X-Request-ID
    _ = try app.useAll(am.mw.accessLog(State, .json));        // structured log
    _ = try app.useAll(am.mw.metrics(State, &metrics_counters));

    _ = try app.get("/metrics", am.mw.metricsHandler(State, &metrics_counters));
    _ = try app.get("/health", health);
    // … your routes …
}
```

Now `GET /metrics` exposes a Prometheus text exposition, and every
request line is a JSON object with a stable `req_id`.

---

## Metrics — what's exposed

All series share the `akamata_` prefix. Cardinality is fixed at compile time
— there's no per-path label, so a misbehaving client can't blow up your
TSDB.

| Series | Type | Labels | Notes |
|---|---|---|---|
| `akamata_requests_total` | counter | — | All HTTP requests served |
| `akamata_requests_in_flight` | gauge | — | Currently executing |
| `akamata_requests_by_status` | counter | `class` ∈ {1xx..5xx} | Status class breakdown |
| `akamata_requests_by_method` | counter | `method` ∈ {GET, POST, …, OTHER} | 8 fixed values |
| `akamata_request_latency_seconds` | histogram | `le` ∈ {0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, +Inf} | Cumulative, Prometheus-compatible |
| `akamata_request_latency_seconds_count` | (histogram aux) | — | Total observations |
| `akamata_request_latency_seconds_sum` | (histogram aux) | — | Sum of latencies (seconds) |
| `akamata_process_resident_memory_bytes` | gauge | — | RSS at scrape time |
| `akamata_process_start_time_seconds` | gauge | — | Unix time of first request |
| `akamata_process_uptime_seconds` | gauge | — | Seconds since first request |

### Useful PromQL

```promql
# Request rate by status class
sum by (class) (rate(akamata_requests_by_status[1m]))

# P99 request latency
histogram_quantile(0.99, sum by (le) (rate(akamata_request_latency_seconds_bucket[5m])))

# Average latency (sum/count is unbiased; this is the right way)
rate(akamata_request_latency_seconds_sum[5m])
  / rate(akamata_request_latency_seconds_count[5m])

# Error rate (5xx as a fraction of total)
sum(rate(akamata_requests_by_status{class="5xx"}[5m]))
  / sum(rate(akamata_requests_total[5m]))

# Memory growth (catches a leak before it pages)
deriv(akamata_process_resident_memory_bytes[15m])
```

### Histogram bucket choice

Akamata's bucket boundaries (0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1)
are tuned for **sub-millisecond services** — the median of a healthy
Akamata handler is in the 30–80 µs range. If your handlers do significant
I/O (network, large DB), edit `latency_buckets` in `src/mw/metrics.zig` to
shift the range higher. There is no API yet to customise bucket boundaries
per-deployment; that's tracked under "future work" below.

---

## Access logs

`am.mw.accessLog(State, .json)` writes one structured line per request:

```json
{
  "ts_unix_us": 1779499034102345,
  "req_id": "a64d6f73-2b0e-4ad1-9aa3-8c0f4f2c5d6e",
  "ip": "203.0.113.42",
  "method": "POST",
  "path": "/entries",
  "status": 201,
  "latency_us": 412
}
```

Alternate format `accessLog(State, .combined)` writes Apache combined-style
text, which is easier to grep but harder to ship into Loki/ELK/Datadog.
**For production, use `.json`** — every modern log shipper parses it
natively.

`ip` falls back to the direct peer if no `X-Forwarded-For` header was sent.
Akamata only trusts the first hop and doesn't currently support an explicit
trusted-proxy list (tracked).

---

## Request IDs

The `am.mw.requestId(State)` middleware:

1. Reads `X-Request-ID` from the incoming request if present
2. Mints a fresh UUIDv4 if absent
3. Stores it in `ctx.user_data` so other middleware (access log) can read it
4. Sets `X-Request-ID` on the response

Wire it **before** `accessLog` so the log line carries the same ID:

```zig
_ = try app.useAll(am.mw.requestId(State));
_ = try app.useAll(am.mw.accessLog(State, .json));
```

In a handler, retrieve the current ID via `c.req.header("x-request-id")`
(it's been added to the request headers by the middleware).

For distributed tracing (Zipkin/Jaeger), use `traceparent` instead and
write a thin middleware that does the same plumbing.

---

## Scrape configuration

### Prometheus

```yaml
scrape_configs:
  - job_name: akamata
    metrics_path: /metrics
    scrape_interval: 15s
    static_configs:
      - targets: ['app.internal:8080']
```

### Cloudflare Workers

The `/metrics` endpoint works the same on Workers — point a CF Workers
Analytics Engine or Grafana Agent at it. Note: cold starts reset the
counters (Workers isolates are stateless), so `rate()` over a long
window can underestimate.

For Workers, prefer **wrangler tail** or **Workers Analytics Engine** for
durable observability; treat `/metrics` as a probe rather than a TSDB
source.

---

## Health endpoint

Akamata doesn't ship a built-in `/health` (it would be too opinionated
about what "healthy" means). Wire one explicitly:

```zig
fn health(c: *am.Context(State)) !void {
    // Cheap path: confirm the DB is reachable.
    var stmt = c.db().prepare("SELECT 1") catch return c.serverError("db down");
    defer stmt.deinit();
    _ = stmt.step() catch return c.serverError("db down");
    try c.json(.{ .status = "ok" }, 200);
}
```

For Kubernetes-style liveness + readiness, split into two endpoints —
`/healthz` (liveness, just `return 200`) and `/readyz` (readiness, does
the DB ping).

---

## Future work

- **Per-path latency labels.** Requires the router to expose its path
  template. Trade-off: cardinality vs. usefulness. Tracked.
- **OpenTelemetry export.** Direct OTLP/gRPC push instead of a scrape model.
- **Histogram bucket customisation.** Currently hard-coded; should be
  a runtime option on `Counters.init` or similar.
- **Exemplars.** Linking high-latency observations to trace IDs.

If any of these blocks your rollout, open an issue with the use case.
