# Performance follow-ups

What we tried, what landed, and what's worth attempting next. Recorded so
the next person doesn't redo dead-end experiments.

---

## Baseline (May 2026, macOS arm64)

| Endpoint | Akamata | Go `net/http` | Hono on Bun |
|---|---:|---:|---:|
| `GET /hello` (static) | 175 k req/s | 208 k | 165 k |
| `POST /echo` (JSON) | 181 k req/s | 175 k | 128 k |
| `GET /db/:id` (sqlite) | 91 k req/s | 46 k (40% errors) | 138 k |
| P99 latency | 80 µs – 200 µs | similar | 100 µs – 300 µs |
| RSS after 5 min of 53 M requests | flat at 2.5 MB | flat ~10 MB | flat ~80 MB |

Akamata leads on `echo` and `db` (versus the same-language-class Go); the
35 k gap on `hello` is the remaining headroom this doc tracks.

---

## What we tried in this round

### 1. Direct streaming write (no intermediate arena buffer)

Change: in `serve.zig`, replace

```zig
var alloc_w: Io.Writer.Allocating = .init(arena);
try res.writeTo(&alloc_w.writer);
const out = alloc_w.writer.buffered();
w.writeAll(out); w.flush();
```

with `res.writeTo(w)` straight into the socket-buffered writer.

Hypothesis: saves one full-response copy through the arena.

**Result with 4 KB socket buffer:** `/echo` regressed by ~14 % because
multi-header `w.print()` calls overflowed the buffer and triggered extra
`send()` syscalls.

**Result with 16 KB socket buffer:** `/echo` recovered to ~174 k, but
`/hello` dropped to 169 k. Net wash, within measurement noise.

**Verdict: kept the arena-buffer + single-shot writeAll pattern.** It's
also better for the eventual TLS / proxy case (one contiguous payload
per response).

---

## Candidates not yet attempted

Sorted by estimated effort × impact.

### Lower-effort wins (1-2 days each)

| Idea | Expected gain | Risk |
|---|---|---|
| `memchr`-based header parser (instead of `std.mem.indexOf` per name) | +5-10 % on `/hello` | Low |
| Pre-sized arena per connection (skip first 16-KB realloc) | +2-5 % | Low |
| Skip the linear header table for known fields (`content-length`, `connection`) — cache via small inline array | +1-3 % | Low |
| Status line precomputed table (avoid `phrase()` lookup per request) | +1 % | Low |
| `accept_thread_count` autotune from `cpu_count()` | Variable; helps under-provisioned defaults | Low |

### Mid-effort (3-5 days)

| Idea | Expected gain | Risk |
|---|---|---|
| Reactor + readiness (kqueue/epoll) instead of one thread per accept loop | +20-30 % on `/hello`; closes most of the Go gap | High — changes the threading model; needs full re-test of the stress matrix |
| `SO_REUSEPORT` so each accept thread has its own listener fd | +5-15 % | Medium — different from current behaviour on Linux vs macOS |
| HTTP/2 (over TLS via OpenSSL) | More throughput on multiplexed clients, but **not** on wrk | High |
| `io_uring` on Linux | Likely +10-20 % on Linux | Medium — keeps macOS on the current path |

### Larger investigations

- **Per-request arena allocator audit.** Profile shows `arena.alloc` is
  the dominant non-syscall cost. A custom bump allocator with no metadata
  overhead would shave a meaningful slice.
- **Response struct pooling.** Right now `Response.init` zeros + sizes an
  `ArrayList` per request. A thread-local pool of pre-allocated Response
  objects (clear-on-acquire) would amortise that.
- **JSON serialisation rewrite.** `std.json.Stringify.value` is currently
  the largest CPU cost in `/echo`. A schema-aware emitter generated from
  the response type at comptime would beat it by 2-3×.

---

## How to reproduce

```bash
zig build -Dexample=bench -Doptimize=ReleaseFast
./zig-out/bin/bench &

# /hello
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello

# /echo
cat > /tmp/wrk_echo.lua <<'LUA'
wrk.method = "POST"
wrk.body   = '{"name":"x","n":42}'
wrk.headers["content-type"] = "application/json"
LUA
wrk -t8 -c256 -d10s --latency -s /tmp/wrk_echo.lua http://127.0.0.1:8080/echo

# /db (round-robins ids 1-3)
cat > /tmp/wrk_db.lua <<'LUA'
math.randomseed(os.time())
request = function() return wrk.format("GET", "/db/" .. tostring(math.random(1,3))) end
LUA
wrk -t8 -c256 -d10s --latency -s /tmp/wrk_db.lua http://127.0.0.1:8080
```

For longer / more adversarial runs see `docs/benchmarks-long-run.md`.

## Methodology notes (so future numbers stay comparable)

1. **macOS results have ±3-5 % jitter run-to-run.** Take the median of
   three 10-second runs after a 30-second warmup before drawing conclusions.
2. **Loopback measurements undercount syscall cost** (no actual NIC). A
   real Linux box on a 10 Gbps NIC will see different relative gaps.
3. **wrk reports the *issued* request count.** Always cross-check
   `Non-2xx or 3xx responses` — non-zero means we're not benchmarking what
   we think we are.
4. **RSS sampling at 10-second intervals is enough.** A leak shows up as
   linear growth; transient spikes settle within one sampling window.
