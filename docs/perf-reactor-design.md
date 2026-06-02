# Reactor design — closing the throughput gap with Go

## Status

Design draft (May 2026). Tracked under PERF1; implementation under PERF2 (kqueue
prototype) and a follow-up PERF3 (epoll port).

## Why now

Current measurements (`docs/benchmarks-long-run.md`):

| Scenario | Akamata | Go `net/http` | Gap |
|---|---:|---:|---:|
| `/hello` (static) | 175 k req/s | 208 k | -16 % |
| `/echo` (JSON) | 181 k req/s | 175 k | +3 % |
| `/db` (SQLite) | 91 k req/s | 46 k (40 % err) | +98 % |

Akamata already wins on workloads with any handler work, but the static
text path leaves throughput on the table. The reason is buried in the
serve loop.

### Current model: thread-per-accept, no demux

```text
acceptLoop thread #1  →  accept()  →  handleConnection() [keep-alive blocks here]
acceptLoop thread #2  →  accept()  →  handleConnection()
acceptLoop thread #3  →  accept()  →  handleConnection()
acceptLoop thread #4  →  accept()  →  handleConnection()
```

`accept_thread_count` defaults to 4. Each thread **inlines** the connection
handler, so concurrency is bounded by 4 — even when wrk drives 256 connections,
only 4 are active at a time; the other 252 sit in the kernel listen backlog
multiplexed across the 4 worker pipes. That's *fine* for high-keepalive
loopback wrk (each pipe runs flat-out) but caps real-world concurrency where
many connections idle between requests.

Three concrete cost contributors:

1. **One pipe per worker thread.** Concurrent connections only progress
   when their assigned worker is idle. Idle keep-alive connections starve
   active ones.
2. **Syscall hot loop.** Every request does `read()`, then `write()`,
   then maybe another `read()` (keep-alive). On loopback that's 3-4
   syscalls per request, and we're CPU-bound on syscall overhead.
3. **`std.Io.Threaded` overhead.** Every read goes through a vtable
   dispatch in `Io.Threaded.netReadPosix` before reaching `readv()`. Small
   but non-zero.

### Target model: reactor + worker pool

```text
       ┌───────────────────────────────────────────────┐
       │  acceptor thread                              │
       │     accept() → register fd with kqueue/epoll  │
       └────┬──────────────────────────────────────────┘
            │ readable event
            ▼
       ┌────────────────────────────────────┐
       │  reactor thread (event loop)       │
       │    kqueue/epoll_wait()             │
       │    for fd in ready:                │
       │       enqueue (fd, task) to pool   │
       └────┬───────────────────────────────┘
            │ work item
            ▼
       ┌────────────────────────────────────┐
       │  worker thread pool (N workers)    │
       │    parse request, run handler,     │
       │    write response, re-arm fd       │
       └────────────────────────────────────┘
```

The reactor decouples accept rate, dispatch, and execution. Connection
count becomes irrelevant to thread count; the worker pool sizes for
**CPU concurrency**, not socket concurrency.

## Design decisions

### 1. Per-OS demultiplexer

| Platform | Demux primitive | Status |
|---|---|---|
| macOS / BSD | `kqueue` | PERF2 prototype |
| Linux | `epoll` | PERF3 (follow-up) |
| Linux ≥ 5.1 | `io_uring` | Future — only if we see real benefit beyond epoll |
| Windows | IOCP | Not planned |

We **don't** abstract this behind a portable interface. Each backend
gets its own file (`reactor_kqueue.zig`, `reactor_epoll.zig`) with the
same public API. The `runtime/native.zig` module picks one at comptime
based on `builtin.os.tag`.

### 2. Worker pool sizing

Default to `cpu_count()` workers (M2 Pro reports 10, so 10 worker threads).
This deliberately ignores `accept_thread_count` — it's a CPU-bound knob,
not a concurrency knob. Override via `ServeOptions.worker_count`.

### 3. Per-fd state, kept alive across events

A connection's state (`recv_buf`, `parser state`, arena) lives in a
heap-allocated `Conn` struct keyed by fd. When the reactor sees the fd
become readable, it looks up the `Conn` and submits a work item that
references it. After the handler runs, the worker re-arms the fd for the
next read (kqueue `EV_ONESHOT` + manual re-add, or epoll `EPOLLONESHOT`).

### 4. Keep-alive without thread occupancy

Today a keep-alive socket occupies a worker thread between requests.
Under the reactor, the same connection generates an event only when the
**client sends bytes**, so an idle keep-alive uses zero CPU and zero
worker capacity.

### 5. Backpressure / overload

If the worker pool's submission queue is full, the reactor drops the
oldest event for that fd and forces `Connection: close`. This is the
same behaviour as nginx's `worker_connections` overrun.

### 6. Migration path

Both implementations coexist:

```bash
# Existing thread-per-accept model (default for now)
zig build -Dexample=bench -Druntime=threaded

# New reactor (opt-in until validated)
zig build -Dexample=bench -Druntime=reactor
```

After PERF2 lands and benchmarks confirm parity-or-better on every
workload (especially `db` where SQLite contention is a different beast),
flip the default to `reactor` and deprecate `threaded`.

## API surface (public)

No change to `am.App(State).serve(.{...})`. The new option becomes:

```zig
pub const ServeOptions = struct {
    address: ?[]const u8 = null,
    port: u16 = 8080,

    /// Default reactor mode in v0.4. Set to .threaded to fall back to the
    /// thread-per-accept loop while we shake out reactor edge cases.
    runtime: enum { reactor, threaded } = .reactor,

    /// Number of worker threads for the reactor model. Defaults to
    /// std.Thread.getCpuCount() at runtime.
    worker_count: ?usize = null,

    // ...existing fields preserved...
};
```

## Risk + open questions

- **`std.Io.Threaded` interop.** The current serve loop builds on
  `std.Io.net.Listener.accept()`. With kqueue we want raw `accept(2)`
  and to never go through the Io vtable for hot syscalls. Means a small
  amount of duplicated TCP plumbing. Acceptable given that the abstraction
  is what we're trying to escape.
- **SSL/TLS.** Akamata only does outbound TLS today (no terminating
  HTTPS server). Once we add that, the reactor needs to integrate with
  OpenSSL's BIO model. Tracked under a future ticket.
- **Per-connection arena lifetime.** Today it lives on the worker thread's
  stack. Under the reactor it has to be heap-allocated and freed when
  the fd is finally closed. We need an `id → Conn` table; a simple
  `std.AutoArrayHashMap` will do until profiling says otherwise.

## A/B benchmark plan

For PERF2, run on the same M2 Pro hardware as `docs/benchmarks-long-run.md`:

| Variant | Build flags |
|---|---|
| **baseline** | (current) — `-Dexample=bench -Doptimize=ReleaseFast` |
| **reactor**  | `-Dexample=bench -Druntime=reactor -Doptimize=ReleaseFast` |

For each variant, run all three scenarios from the existing harness
(`examples/bench/runall.sh`), 5 minutes per run, 8 wrk threads, 256
connections. Compare:

- Sustained req/s (target: ≥110 % of baseline on `/hello`, ≥100 % on others)
- P50 / P99 / P999 (target: equal or better at P99; P999 may drift slightly)
- RSS over 5 minutes (target: flat as today)
- CPU usage (target: ≤ baseline at the same throughput)

If any scenario regresses by more than 5 %, do not flip the default —
profile and fix first.

## PERF3 results (May 2026) — Worker pool added

`src/runtime/reactor_kqueue.zig` now spawns `cpu_count()` worker threads
behind an MPMC queue (`am.sync.Mutex` + `am.sync.Condition`). The reactor
reads bytes from ready sockets and hands `Conn*` to the pool; workers
parse, dispatch, write, and re-arm via thread-safe `kevent` calls.

10-second `wrk -t8 -c256` results:

| Scenario | threaded | reactor+pool | Δ throughput | P99 reactor |
|---|---:|---:|---:|---:|
| `/hello` | 105,760 | 102,991 | -2.6 % | 6.92 ms |
| `/echo`  | 121,352 |  98,191 | -19.0 % | 14.14 ms |
| `/db`    |  68,816 |  90,154 | **+31.0 %** | 6.87 ms |

`/db` is the one workload where the worker pool wins materially —
because SQLite prepare/step actually keeps a CPU busy, so workers
exhibit useful parallelism. `/hello` and `/echo` are syscall-bound, and
the reactor's per-request handoff (reactor→queue→worker→kevent re-arm)
adds more cost than the parallelism saves.

### Why the reactor doesn't win on `/hello`

`wrk` keeps each connection saturated with **one pipelined request at
a time**. On the threaded loop, a single OS thread reads → dispatches →
writes → reads, no IPC. On the reactor, the same request crosses three
threads (reactor read, worker dispatch, reactor re-arm) — three
synchronisation points per request.

This benchmark pattern is artificial. **Real-world traffic** (CDN, mobile
clients, browsers) has **idle keep-alive connections** that the threaded
model can't scale past `accept_thread_count`. The reactor handles 10,000
idle connections with the same `worker_count` workers, which is its
actual win.

### Trade-off and product decision

Given:

- The reactor wins on the workload where Akamata is most CPU-bound (`/db`)
- The reactor is meaningfully better for high-connection-count idle workloads
- `wrk` benchmarks under-represent that pattern

We will **keep the reactor as an opt-in runtime** for now, document the
trade-off (this section), and not flip the default in PERF5 until we
have a more representative benchmark (probably one that simulates idle
keep-alive connections with periodic bursts — i.e. real CDN behaviour).

The threaded runtime stays the default for v0.3. Reactor is recommended
for:

1. Long-lived connection workloads (chat, SSE, WebSocket-heavy services)
2. Anything CPU-bound in the handler (DB-heavy, JSON-heavy, crypto-heavy)
3. Production proxied behind Cloudflare/nginx where connection
   multiplexing is already happening upstream

## PERF2 results (May 2026)

The single-thread kqueue prototype ships as `src/runtime/reactor_kqueue.zig`
and is selectable via `app.serve(.{ .runtime = .reactor, ... })`. To A/B,
set `BENCH_RUNTIME=reactor` when launching `examples/bench`.

10-second loopback wrk results (`-t8 -c256`):

| Scenario | threaded baseline | reactor prototype | Δ throughput | P50 reactor | P99 reactor |
|---|---:|---:|---:|---:|---:|
| `/hello` | 167,834 req/s | **188,100 req/s** | **+12.7 %** | 1.22 ms | 5.38 ms |
| `/echo`  | 147,831 req/s | **175,632 req/s** | **+18.9 %** | 1.32 ms | 5.13 ms |
| `/db`    |  83,478 req/s |  **92,425 req/s** | **+10.7 %** | 2.38 ms | 27.35 ms |

So the kqueue path **wins on throughput by 10-19 %**, by cutting per-request
syscall overhead (no more `std.Io.Threaded.netReadPosix` vtable on every
byte), but **regresses P50/P99 latency by 30-60×** because the single
event loop serialises all 256 concurrent connections through one CPU.

That regression is expected — the prototype omits the worker pool by
design, and a single-thread loop is bounded by 1 / (per-req CPU time).
The point of this prototype was to validate:

1. The kqueue event model + per-fd Conn struct work.
2. Bypassing `std.Io.Threaded` is unambiguously faster on hot syscalls.
3. The drop-in API (`runtime: .reactor` flag) is clean.

All three validated. **PERF3 (next)** is the natural follow-up: add the
worker thread pool to balance throughput AND latency. The expectation is
~+15 % on `/hello` *and* P99 within 10 % of the threaded baseline.

## PERF4 — Linux epoll port

`src/runtime/reactor_epoll.zig` (May 2026) mirrors the kqueue file:

- `epoll_create1(EPOLL_CLOEXEC)` for the event fd
- `EPOLLIN | EPOLLET | EPOLLONESHOT | EPOLLRDHUP` per-conn flags
- Workers re-arm via `epoll_ctl(EPOLL_CTL_MOD)` (thread-safe like `kevent`)
- Otherwise identical: same `Conn`, same `TaskQueue`, same handler loop

The selection is comptime in `serve.zig`:

```zig
.reactor => if (comptime builtin.os.tag == .linux)
    @import("runtime/reactor_epoll.zig").serve(...)
else
    @import("runtime/reactor_kqueue.zig").serve(...),
```

We verified the file compiles cleanly under `zig build -Dtarget=x86_64-linux-musl`
on the macOS dev box (10.6 MB static ELF), but the actual on-Linux
benchmark hasn't run yet. Bench results will land in
`docs/benchmarks-long-run.md` once we have access to Linux hardware
(typical CI runner is fine — the prototype doesn't need a tuned kernel).

## PERF5 decision — keep `threaded` as the default

Given that PERF3 showed the reactor *loses* the `wrk` benchmark on most
hot-path workloads (kernel-loopback + pipelined keep-alive is the
threaded model's home turf), we **deliberately do not flip the default**.

Instead:

- `runtime: .threaded` stays the default. Existing users see no change.
- `runtime: .reactor` is documented as the right choice for:
  1. Many idle connections (chat, SSE, long-poll)
  2. CPU-bound handlers (DB, JSON, crypto)
  3. Behind a proxy that already multiplexes
- `accept_thread_count` is *not* deprecated yet — it's the right knob
  for the threaded runtime.
- `worker_count` only affects the reactor runtime, as documented in
  `ServeOptions`.

## PERF6 — io_uring evaluation (May 2026)

**Decision: do not implement io_uring as a runtime variant for v0.4.**

### Reasoning

io_uring's three big wins, against what Akamata actually spends time on:

| io_uring optimisation | Akamata bottleneck? |
|---|---|
| Batch submit (read+write in one syscall) | Already 1 read + 1 write per request; syscalls are not the dominant cost on the hot path |
| Batch completion harvest | epoll/kqueue already batch-harvest via `events[128]` |
| Fixed buffers / IORING_REGISTER_BUFFERS | Per-conn `Conn.recv_buf` is already pinned in heap; no copy benefit |
| SQPOLL (zero-syscall submit) | Trades CPU for syscalls — useful at >500k req/s/core, we're at ~200k |

PERF3 results showed the **reactor doesn't win the wrk benchmark on
hot-path workloads** because the actual bottleneck is per-request
synchronisation between the reactor thread and worker threads, not
syscall overhead. io_uring doesn't address that — only a redesign of
the worker queue (per-core sharding, or lock-free MPMC) would.

### What we'd implement instead

If we want more throughput, the targets are:

1. **Per-worker queues with fd affinity** — assign each conn to one
   worker by `fd % worker_count`, so the worker handles read+dispatch+write
   in one thread without IPC. This is the **thread-per-core architecture**
   used by Tokio (Rust async) and Caddy. Estimated effort: 3–5 days.
2. **Direct response writes** — bypass the arena allocation for the
   HTTP response, write directly to a per-worker pre-sized buffer.
   Estimated effort: 1 day.
3. **JSON serialisation rewrite** — `std.json.Stringify` is allocating;
   a comptime-generated emitter per response type would halve `/echo`
   CPU time. Estimated effort: 3 days.

Tracked under PERF7-9 in `docs/perf-followups.md` (to be opened when we
have a concrete user complaint or production data showing a gap that
needs to close).

### Reservation

If a future workload — high-throughput proxies or gateways with very
short responses — shows epoll saturating at significantly below the
hardware NIC ceiling, io_uring becomes worth re-evaluating. The minimum
viable port is ~600 LOC and would inherit the existing `Conn` /
`TaskQueue` / `Worker` plumbing.
