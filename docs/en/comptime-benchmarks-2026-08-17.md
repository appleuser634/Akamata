# Compile-time routing benchmark — 2026-08-17

This benchmark evaluates scaling rather than only maximum Hello World rate.
Both variants use the same `App`, HTTP server, handlers, and response core.
`runtime` uses ordinary registration; `static` uses `Routes`/`mountStatic` and
static middleware composition. Values are medians of three ReleaseFast runs on
an Apple M2 (8 cores, 16 GB), macOS 26.5, Zig 0.16.0, oha 1.15.0, loopback,
16 connections, and 3 seconds per run.

## Static-path route scaling

|Routes|Runtime req/s|Static req/s|Delta|Runtime P50/P95/P99|Static P50/P95/P99|Runtime/Static RSS|Runtime/Static binary|
|---:|---:|---:|---:|---|---|---:|---:|
|1|153,721|148,967|-3.09%|0.091/0.178/0.336 ms|0.089/0.197/0.385 ms|1,824/1,808 KB|494,320/494,480 B|
|10|151,394|151,160|-0.15%|0.091/0.183/0.341 ms|0.091/0.192/0.348 ms|1,808/1,808 KB|495,984/496,320 B|
|100|149,446|145,195|-2.84%|0.090/0.191/0.388 ms|0.090/0.206/0.404 ms|1,904/1,888 KB|527,184/527,392 B|
|500|151,495|147,871|-2.39%|0.090/0.185/0.344 ms|0.090/0.210/0.442 ms|2,288/2,304 KB|725,664/781,056 B|

The 10-route result is equivalent. Static results at 100 and 500 routes use
the shared fallback because the specialization threshold is 32. A prototype
that unrolled all 500 routes measured only 137,922 req/s and 837,728 bytes;
that finding caused the selective fallback. The remaining 2–3% movement is
within the observed short-run spread and is not presented as a speedup.

## Route shape and middleware scaling at 100 routes

|Case|Runtime req/s|Static req/s|Delta|Runtime P99|Static P99|
|---|---:|---:|---:|---:|---:|
|Parameter, middleware 0|144,575|140,845|-2.58%|0.420 ms|0.474 ms|
|Wildcard, middleware 0|142,714|144,007|+0.91%|0.428 ms|0.378 ms|
|Static, middleware 3|149,403|146,601|-1.88%|0.399 ms|0.385 ms|
|Static, middleware 6|148,558|145,993|-1.73%|0.413 ms|0.414 ms|

Adding middleware or routes does not produce a monotonic throughput collapse.
Static middleware removes slice/index dispatch, but at this network-level
workload the difference is below run-to-run noise. It is therefore offered for
static composition and code generation, not marketed as a measured throughput
win.

## Existing hot-path regression sentinel

The ordinary one-route `GET /hello` path was compared with pre-change commit
`c7b0811`, using wrk, 4 threads, 16 connections, 5 seconds, three runs. The
order-adjusted current median was 171,455 req/s versus 171,809 req/s (-0.21%);
ranges overlap. P50 was 73–74 µs. No material regression was detected.

The server's existing 100-request connection-recycle default causes wrk read
errors and makes short P99 noisy; this known behavior is unchanged.

## Size and startup observations

An application that does not instantiate the new APIs changed from 1,850,776
to 1,850,584 bytes (-192 bytes) for the native benchmark and from 98,894 to
99,104 bytes (+210 bytes, +0.21%) for the Workers chat WASM.

At 1/10/100 static routes, specialization/fallback added 160/336/208 bytes.
The 500-route static benchmark added 55,392 bytes (+7.63%); this is a known
generic-instantiation cost and a reason not to specialize large graphs further.
Readiness measurements were noisy (roughly 180–360 ms) and include process and
polling overhead, so they are recorded in the JSON but not used as a gate.

Reproduce with:

```console
DURATION=3s CONNECTIONS=16 OUT=/tmp/router.csv \
  examples/router_bench/run_matrix.sh
```

Aggregates are in
[`benchmark-results/20260817-comptime-router.json`](../../benchmark-results/20260817-comptime-router.json).
