# Benchmarks

> **Historical data:** the figures below did not retain an exact commit and
> raw output, so they are not claims about the current revision. Run
> `OUTDIR=./benchmark-results bash examples/bench/runall_ext.sh` and retain
> the generated JSON, which records the commit, UTC timestamp, and OS.
> The reactor measurements are historical only: `.reactor` currently fails
> closed with `error.ExperimentalRuntimeDisabled`. Use `.threaded` in current
> deployments until parser limits, deadlines, and connection lifecycle reach
> safety parity.

These measurements compare Akamata with several server implementations under specific local workloads. They are historical snapshots, not performance guarantees.

The recorded runs date from May 2026. Their exact Git commit was not captured in the original results; use the commands and sources linked below to reproduce them on the current revision.

## Execution environment

- macOS 26.0.1, Apple Silicon (M2 Pro, 10 cores)
- Zig 0.16.0 ReleaseFast
- Go 1.24.5
- Bun 1.3.0 / Hono 4.12.x
- wrk 4.2.0
- Loopback (127.0.0.1), wrk and server are the same host

## Bench parameters

```
threads=8  connections=256  duration=10s
wrk -t8 -c256 -d10s --latency
```

Three scenarios:

| Scenario | Endpoint | Description |
|---|---|---|
| **hello** | `GET /hello` | static text Response. Measuring framework overhead |
| **echo** | `POST /echo` | JSON Read `{"name","n"}` and return in JSON |
| **db** | `GET /db/:id` | Single row SELECT with SQLite (in-memory) |

Implementation:
- Akamata: [`examples/bench/src/main.zig`](../../examples/bench/src/main.zig) (`am.App` + `am.db.openSqlite`)
- Go: [`examples/bench/go/main.go`](../../examples/bench/go/main.go) (`net/http` + `modernc.org/sqlite`)
- Hono on Bun: [`examples/bench/hono/index.ts`](../../examples/bench/hono/index.ts) (`hono@4` + `bun:sqlite`)

---

## v0.4 Extended Benchmark (6+1 Comparison with Competition, May 2026)

Comparing 7 implementations on the same machine and with the same workload:

| # | Implementation | Runtime/Language | Built-in DB Driver |
|---|---|---|---|
| 1 | **Akamata threaded** | Zig 0.16 (thread-per-conn) | sqlite3 amalgamation |
| 2 | **Akamata reactor** | Zig 0.16 (thread-per-core, kqueue) | sqlite3 amalgamation |
| 3 | Go net/http | Go 1.24 | modernc.org/sqlite (pure Go) |
| 4 | Rust Axum | Rust 1.90 (tokio) | rusqlite (bundled) |
| 5 | Bun raw (`Bun.serve`) | Bun 1.3 (JavaScriptCore) | bun:sqlite (native) |
| 6 | Hono on Bun | Bun 1.3 + Hono 4 | bun:sqlite |
| 7 | Node + Fastify | Node 25 + Fastify 5 | better-sqlite3 (native) |

### Throughput (req/s, higher is better)

| Implementation | /hello | /echo | /db |
|---|---:|---:|---:|
| **Akamata threaded** | 189,284 | 192,272 | 99,919 |
| **Akamata reactor** | **221,316** | 215,782 | 113,031 |
| Go net/http | 209,713 | 176,510 | 52,063 ⚠️ |
| Rust Axum | 216,152 | **217,300** | 135,249 |
| Bun raw | 204,688 | 156,280 | 160,370 |
| Hono on Bun | 195,830 | 140,708 | 144,356 |
| Node + Fastify | 91,609 | 68,627 | 79,277 |

⚠️ Go's `/db` is `modernc.org/sqlite` and emits a large amount of 5xx errors under wrk high load (40% non-2xx in previous measurement).
This time too, the error `responses:` is displayed, and the throughput numbers are essentially meaningless.

### Latency (P50 / P99)

| Implementation | /hello P50 / P99 | /echo P50 / P99 | /db P50 / P99 |
|---|---|---|---|
| **Akamata threaded** | **34 µs / 77 µs** | **33 µs / 76 µs** | **65 µs / 191 µs** |
| Akamata reactor | 970 µs / 18.1 ms | 794 µs / 28.6 ms | 2.12 ms / 7.36 ms |
| Go net/http | 585 µs / 9.8 ms | 940 µs / 18.1 ms | 5.08 ms / 24.6 ms |
| Rust Axum | 748 µs / 7.78 ms | 690 µs / 11.9 ms | 1.83 ms / 4.56 ms |
| Bun raw | 1.20 ms / 2.29 ms | 1.51 ms / 12.1 ms | 1.53 ms / 3.56 ms |
| Hono on Bun | 1.26 ms / 2.40 ms | 1.77 ms / 2.53 ms | 1.69 ms / 3.46 ms |
| Node + Fastify | 2.76 ms / 66.4 ms | 3.59 ms / 93.8 ms | 3.18 ms / 22.8 ms |

The historical run recorded a large P99 difference. Treat it as reference data
until the current script reproduces it with retained JSON output.

### Binary/Runtime

| Implementation | Binary | Required runtime |
|---|---|---|
| **Akamata threaded** | **1.8 MB** (single static binary) | None |
| **Akamata reactor** | **1.8 MB** (same binary) | None |
| Go net/http | 13.8 MB | None |
| Rust Axum | 2.7 MB | None |
| Bun raw | n/a | Bun runtime (approximately 100 MB install) |
| Hono on Bun | n/a | Bun + node_modules |
| Node + Fastify | n/a | Node + node_modules |

Akamata + Rust is **size that can be thrown into `FROM scratch` Docker as is**.
Go has a sized difference of 5×. JS series requires runtime body + npm tree.

### Cold start (TTFB)

Measured milliseconds for first `GET /hello` to return 200 (average of 3 times):

| Implementation | TTFB |
|---|---:|
| Akamata threaded | **~50 ms** |
| Akamata reactor | **~47 ms** |
| Go net/http | ~48 ms |
| Rust Axum | ~48 ms |
| Hono on Bun | ~48 ms |
| Node + Fastify | ~48 ms |
| Bun raw | ~167 ms (Bun.serve warms up on first fetch) |

Almost all implementations stick to the `curl --max-time` granularity (50 ms units), with no significant difference.
Only Bun raw is a little slow due to Bun.serve's lazy initialise.

### Resource consumption (sampling under load, 1Hz)

Actual measurement values ​​sampled every second with `ps` + `lsof` while running `wrk` for 10s.
The raw file was written to `/tmp/bench_resources.json` during the run and is not part of the repository. Reproduce it with `bash examples/bench/resources_all.sh`.

#### Idle (1 second after startup, before request)

| Implementation | RSS | CPU% | Thread | FD |
|---|---:|---:|---:|---:|
| **Akamata threaded** | **3.3 MB** | 0.0% | 8 | 9 |
| Akamata reactor | 3.5 MB | 0.0% | 11 | 39 |
| Rust Axum | 3.6 MB | 0.0% | 11 | 13 |
| Go net/http | 18.3 MB | 0.0% | 9 | 8 |
| Bun raw | 25.5 MB | 0.1% | 5 | 10 |
| Hono on Bun | 41.7 MB | 0.2% | 13 | 10 |
| Node + Fastify | 46.2 MB | 0.0% | 8 | 36 |

Akamata threaded's **idle RSS is 10% less than runner-up Rust Axum and 1/14 times less than Fastify**.
This can be directly achieved through operations such as Cloudflare Containers where many lightweight instances are lined up.
Effective for cost reduction.

#### /hello under load (10 seconds average)

| Implementation | RSS avg (MB) | RSS peak | CPU% avg | CPU% peak | Thread | FD |
|---|---:|---:|---:|---:|---:|---:|
| **Akamata threaded** | **3.5** | 3.5 | **189%** | 217% | 8 | 17 |
| Akamata reactor | 9.5 | 10.2 | 286% | 328% | 11 | **295** |
| Rust Axum | 21.6 | 25.0 | 305% | 362% | 11 | 269 |
| Go net/http | 38.1 | 41.1 | 383% | 451% | 19-22 | 264 |
| Bun raw | 42.0 | 44.0 | **89%** | 101% | 5-8 | 266 |
| Hono on Bun | 67.7 | 70.8 | 90% | 101% | 13 | 266 |
| Node + Fastify | 113.2 | 126.0 | 87% | 100% | 8 | 273 |

#### /db (SQLite) Under load — RSS tends to increase with DB workloads

| Implementation | RSS avg (MB) | CPU% avg | Notes |
|---|---:|---:|---|
| **Akamata threaded** | **3.1** | 270% | Directly link SQLite in C, no need for conn pool |
| Akamata reactor | 9.7 | 436% | per-worker arena + 256 conn buffer |
| Rust Axum | 30.6 | 239% | Serialization with rusqlite Mutex, CPU is low but mem is large |
| Go net/http | 77.6 | 374% | modernc.org/sqlite per-conn state large and 40% error |
| Bun raw | 45.4 | 90% | Bun:sqlite (native binding) and memory is Bun heap |
| Hono on Bun | 71.9 | 89% | + Hono runtime |
| Node + Fastify | 120.8 | 81% | better-sqlite3 + Node V8 heap |

### CPU efficiency (req/s ÷ CPU% × 100 = req/s/core)

This is an indicator of "**how many requests can be handled by one core of CPU**".
Cloud pricing is generally determined on a per-vCPU basis, so this is a proxy for cost efficiency.

| Implementation | /hello rps | CPU% | rps/core |
|---|---:|---:|---:|
| Bun raw | 204,688 | 89 | **230,000** ⭐ |
| Hono on Bun | 195,830 | 90 | 217,600 |
| Node + Fastify | 91,609 | 87 | 105,300 |
| **Akamata threaded** | 189,284 | 189 | **100,150** |
| Akamata reactor | 221,316 | 286 | 77,400 |
| Rust Axum | 216,152 | 305 | 70,900 |
| Go net/http | 209,713 | 383 | 54,700 |

**JS (Bun, Hono) wins in rps/core** is because JS is inherently single-threaded.
This is because the JIT brutally optimizes the hot path, so it can use nearly 100% of 1 core.
However, **JS has no parallelism, so it loses in terms of maximum throughput** (upper limit = 1 core).

Akamata threaded **uses the CPU most efficiently in its range while using multiple cores**
Balance type. Rust Axum / Go has an equivalent multi-threaded design, but Akamata threaded
Less than half CPU efficiency.

→ **Case where cost optimization is most important**: Bun-based framework (albeit with an upper limit)
→ **Cases where absolute throughput + parallelism are most important**: Akamata reactor / Rust Axum
→ **When memory budget is most important**: Akamata threaded (one order of magnitude less)

### Scorecard

Winners in each category:

| Category | Winner | Number |
|---|---|---|
| Fastest throughput (/hello) | Akamata reactor | 221k req/s |
| Fastest throughput (/echo) | Rust Axum | 217k req/s |
| Fastest throughput (/db) | Bun raw | 160k req/s (native sqlite) |
| Minimum P99 (/hello, /echo, /db) | **Akamata threaded** | 77 / 76 / 191 µs |
| Minimum binary | **Akamata** | 1.8 MB |
| Minimum idle RSS | **Akamata threaded** | 3.3 MB |
| Minimum /hello RSS under load | **Akamata threaded** | 3.5 MB (1/32 of Fastify) |
| Highest CPU efficiency (rps/core) | Bun raw | 230k rps/core |
| Maximum throughput × binary size | **Akamata reactor** | 221k req/s / 1.8 MB |

### summary

1. **Akamata threaded has lowest P99 in all scenarios** — 35-200 µs range, contention 2-90 ms
2. **Akamata reactor is the top of all forces in /hello throughput** (221k req/s)
3. **Akamata + Rust is the only size that “works immediately with FROM scratch”** (≤3 MB)
4. **Go's sqlite driver is not practical due to /db** (40% error rate) → The advantage of Akamata directly linking to C amalgamation is effective.
5. **Bun raw vs Hono difference is about 10-30 k req/s** = Hono framework overhead visualization
6. **Fastify is very slow on its own** — Node's event loop + synchronous call of `better-sqlite3` may be in a tug of war
7. **Akamata threaded memory consumption is 1/10 ~ 1/34 of contention** — idle 3.3 MB, /hello load 3.5 MB. Cloud run-cost drops dramatically
8. **JS CPU efficiency (rps/core) is surprisingly high** — Bun raw ranks first with 230k rps/core. However, due to the single thread limit, **absolute throughput cannot reach Akamata reactor/Rust**

The verbose output was written to `/tmp/bench_results.json` during the run and is not part of the repository.

---

## v0.4 results (after applying PERF7-9, May 2026)

### Throughput (req/s, higher is better)

| Scenario | Akamata threaded | Akamata reactor | Go net/http | Hono on Bun |
|---|---:|---:|---:|---:|
| **hello** | 175,664 | **213,023** | 203,147 | 184,368 |
| **echo** | 179,270 | **210,124** | 194,217 | 138,514 |
| **db** | 99,107 | **108,183** | 52,409 (40% err) | 141,575 |

`Akamata reactor` outperforms Go in all three scenarios, and is the top of all forces in `hello`/`echo`.
For DB, Hono's `bun:sqlite` (Bun's native high-speed binding) is overwhelmingly faster, but this is a difference in the backend, not the framework overhead.

### Latency P50 / P99

| | /hello P50 / P99 | /echo P50 / P99 | /db P50 / P99 |
|---|---|---|---|
| **Akamata threaded** | **35 µs / 87 µs** | **34 µs / 96 µs** | **66 µs / 189 µs** |
| Akamata reactor | 773 µs / 41 ms | 637 µs / 32 ms | 2.1 ms / 36 ms |
| Go net/http | 617 µs / 23 ms | 833 µs / 13 ms | 5.0 ms / 25 ms |
| Hono on Bun | 1.3 ms / 2.8 ms | 1.8 ms / 2.6 ms | 1.7 ms / 6.0 ms |

`Akamata threaded` is **less than 200µs on all P99s and 10-300x faster than all competitors**. This is
1 connection 1 thread + synchronous read-dispatch-write loop of wrk that rotates with high density
It meshes perfectly with the benchmark pattern.

`Akamata reactor` is the top in throughput, but P99 is the worst. The reason is wrk -c 256
Keeping **256 synchronous keepalive pipes**: reactor with 10 workers
When dividing, P99 increases because 1 worker time-shares 25 connections.

→ **Case where `threaded` is recommended**: Number of simultaneous connections ≤ accept_thread_count × several times
(Normal REST / GraphQL API, with production reverse-proxy first stage)
→ **Case where `reactor` is recommended**: Number of simultaneous connections > hundreds (chat, SSE, WebSocket-heavy)

---

## History of improvement

### v0.2 (15s wrk)

| Akamata before improvement | Akamata 1st improvement | Akamata Production |
|---:|---:|---:|
| hello: 164,919 | 175,194 | 173,344 |
| echo: 143,869 | 167,716 | 183,123 |
| db: 82,464 | 94,136 | 96,784 |

### v0.3 (kqueue reactor MVP, single thread)

| Scenario | threaded | reactor (1-thread) | Δ throughput | P50/P99 reactor |
|---|---:|---:|---:|---|
| /hello | 167k | 188k | +12.7% | 1.22ms / 5.38ms |
| /echo | 148k | 176k | +18.9% | 1.32ms / 5.13ms |
| /db | 83k | 92k | +10.7% | 2.38ms / 27.35ms |

→ Single-threaded reactor increases throughput, but P50 worsens by 30x (1 worker
(to process all conn serially). I realized that I needed a worker pool.

### v0.3.1 (central reactor + MPMC worker pool)

| Scenario | threaded | reactor+pool | Δ throughput |
|---|---:|---:|---:|
| /hello | 105k | 103k | -2.6% |
| /echo | 121k | 98k | -19.0% |
| /db | 69k | 90k | +31.0% |

→ MPMC mutex contention did not improve `/hello`,`/echo`. Parallelization was effective only for CPU-bound `/db`.

### v0.4 (per-worker reactor / thread-per-core, PERF7-9)

A thread-per-core design where each worker has an independent kqueue + dedicated connections.
Completely eliminate MPMC mutex, accept only single thread to round-robin to worker pipe
Delivery. Plus per-worker 16KB send buffer (PERF8) + comptime JSON emitter (PERF9).

| Scenario | threaded (v0.4) | reactor (v0.4) | vs baseline (v0.3) |
|---|---:|---:|---:|
| /hello | 175k | **213k** | +13% vs Akamata threaded best |
| /echo | 179k | **210k** | +15% |
| /db | 99k | **108k** | +9% |

---

## RSS / Memory Stability

5 minute `/echo` long run (53M requests):

```
t=0s    3,152 KB
t=10s   3,536 KB    (peak — alloc warmup)
t=30s   2,688 KB    (released)
t=60s   2,560 KB    (settled, FLAT for the rest)
end     2,448 KB
```

→ **No memory leak**, converged to 2.5 MB for 5 consecutive minutes. See `docs/en/benchmarks-long-run.md`.

---

## detailed wrk output

### Akamata threaded

```
$ wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello
  Latency Distribution
     50%   35.00us
     75%   45.00us
     90%   56.00us
     99%   87.00us
Requests/sec: 175,664
```

### Akamata reactor (thread-per-core)

```
$ BENCH_RUNTIME=reactor ./bench &
$ wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello
  Latency Distribution
     50%  773.00us
     75%    1.22ms
     90%    3.36ms
     99%   41.19ms
Requests/sec: 213,023
```

### Go net/http

```
$ wrk -t8 -c256 -d10s --latency http://127.0.0.1:8081/hello
  Latency Distribution
     50%  617.00us
     75%    2.30ms
     90%    5.40ms
     99%   23.18ms
Requests/sec: 203,147
```

### Hono on Bun

```
$ wrk -t8 -c256 -d10s --latency http://127.0.0.1:8082/hello
  Latency Distribution
     50%    1.32ms
     75%    1.46ms
     90%    1.58ms
     99%    2.76ms
Requests/sec: 184,368
```

---

## Steps to reproduce

```bash
brew install wrk go bun

# 1. ベンチサーバをビルド
zig build -Dexample=bench -Doptimize=ReleaseFast
(cd examples/bench/go && go build -o /tmp/yt-bench-go .)
(cd examples/bench/hono && bun install)

# 2. 比較ベンチ
cat > /tmp/wrk_echo.lua <<'LUA'
wrk.method = "POST"
wrk.body   = '{"name":"x","n":42}'
wrk.headers["content-type"] = "application/json"
LUA

cat > /tmp/wrk_db.lua <<'LUA'
math.randomseed(os.time())
request = function() return wrk.format("GET", "/db/" .. tostring(math.random(1,3))) end
LUA

# Akamata threaded (port 8080)
./zig-out/bin/bench &
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello
pkill bench

# Akamata reactor (port 8080)
BENCH_RUNTIME=reactor ./zig-out/bin/bench &
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8080/hello
pkill bench

# Go (port 8081)
/tmp/yt-bench-go &
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8081/hello
pkill yt-bench-go

# Hono (port 8082)
(cd examples/bench/hono && bun run index.ts) &
wrk -t8 -c256 -d10s --latency http://127.0.0.1:8082/hello
pkill -f index.ts
```

---

## summary

Akamata achieves **better throughput than Go for all three workloads** in v0.4,
P99 achieved an advantage of more than 10x over all three other frameworks. This makes the runtime selection:

- `threaded` — the only enabled native runtime in the current release
- `reactor` — historical benchmark subject; currently disabled

By using them properly, you can bring out the optimal performance characteristics for each scenario.

See [`docs/en/perf-reactor-design.md`](perf-reactor-design.md) for design and implementation details.
