# Performance regression report — 2026-08-17

This report compares the current developer-experience revision (`74fbe89`) with its pre-change baseline (`3a18d6c`) on the same machine, compiler, benchmark application, and load generator.

## Conclusion

**No material performance regression was detected.** At the stable 16-connection workload, median throughput changed by +0.14% for hello, +0.07% for echo, and -1.38% for DB. All three-run ranges overlap and are consistent with scheduler, thermal, and SQLite mutex variance.

Idle RSS was identical at 3,056 KB. The ReleaseFast binary grew by 320 bytes (+0.017%). Loaded RSS moved between -2.2% and +4.3% depending on the scenario, within the noise of a single 1 Hz resource run.

## Environment and method

- Apple M2, 8 cores (4 performance + 4 efficiency), 16 GB
- macOS 26.5 / Darwin 25.5.0 arm64
- Zig 0.16.0, wrk 4.2.0_2, ReleaseFast
- HTTP/1.1 over loopback; server and load generator on the same host
- Current: `74fbe89ad5aadfaaf0d9644f20bbd6b883935274`
- Baseline: `3a18d6c`

Each revision was built in a separate worktree. The application, routes, SQLite workload, and server options were identical. Historical figures used an M2 Pro with ten cores and are therefore not treated as a regression baseline.

## Stable 16-connection A/B

Median of three runs with `threads=4 connections=16 duration=5s`:

|Scenario|Current req/s|Baseline req/s|Delta|Current P50|Baseline P50|Current P99|Baseline P99|
|---|---:|---:|---:|---:|---:|---:|---:|
|`GET /hello`|171,639|171,404|**+0.14%**|74 µs|74 µs|310 µs|380 µs|
|`POST /echo`|169,851|169,728|**+0.07%**|75 µs|74 µs|543 µs|378 µs|
|`GET /db/:id`|86,028|87,234|**-1.38%**|148 µs|146 µs|1.02 ms|0.99 ms|

Throughput ranges were 170,547–171,857 versus 160,037–171,624 for hello; 169,590–169,861 versus 169,557–170,495 for echo; and 85,409–87,562 versus 85,771–87,524 for DB. Five-second P99 is sensitive to individual scheduler stalls; the echo P99 movement is not accompanied by a throughput or P50 regression.

## Existing 256-connection profile

Median of three `threads=8 connections=256 duration=10s` runs:

|Scenario|Current median|Baseline median|Current range|Baseline range|
|---|---:|---:|---:|---:|
|hello|178,863|177,347|178,715–179,610|176,383–179,053|
|echo|177,665|176,262|177,538–177,883|175,594–178,301|
|db|35,340|47,205|34,195–50,919|38,571–49,871|

Hello and echo are about 0.8% higher in the current revision. DB variance is too large for classification because 256 connections contend on one in-memory SQLite database.

Both revisions produce roughly one wrk read error per 100 successful requests: the server intentionally recycles a connection after the default 100-request limit while wrk attempts to reuse it. These are not HTTP 5xx responses, but reconnect work contaminates P99. Consequently, the historical tens-of-microseconds P99 figures are not directly comparable to this run.

## Resources

|Metric|Current|Baseline|Delta|
|---|---:|---:|---:|
|ReleaseFast binary|1,850,632 B|1,850,312 B|+320 B (+0.017%)|
|Idle RSS|3,056 KB|3,056 KB|0%|
|Hello average RSS|20,859 KB|21,332 KB|-2.2%|
|Echo average RSS|24,426 KB|23,944 KB|+2.0%|
|DB average RSS|23,062 KB|22,105 KB|+4.3%|
|Peak threads|252–253|252–253|equivalent|
|Peak FDs|251–252|252|equivalent|

Loaded RSS is affected by connection-worker stacks and macOS resident-page accounting. The direction is not consistent, while idle RSS, thread counts, and FD counts match; this does not indicate a resource leak.

## Infrastructure findings

Future regression runs should raise `max_requests_per_connection` for steady-state throughput and measure connection recycling separately, retain raw wrk output with the commit, interleave A/B scenario order, require both 16- and 256-connection SQLite profiles, use at least 30 seconds for P99 gates, and replace process-lifetime CPU percentages with interval sampling.

Reproduce the stable profile with:

```console
zig build -Dexample=bench -Doptimize=ReleaseFast
./zig-out/bin/bench
CONN=16 THREADS=4 DURATION=5s examples/bench/run.sh current 8080 hello
CONN=16 THREADS=4 DURATION=5s examples/bench/run.sh current 8080 echo
CONN=16 THREADS=4 DURATION=5s examples/bench/run.sh current 8080 db
```

Machine-readable aggregates are stored in [`benchmark-results/20260817-dx-regression.json`](../../benchmark-results/20260817-dx-regression.json).
