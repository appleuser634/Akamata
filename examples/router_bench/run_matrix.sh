#!/usr/bin/env bash
set -euo pipefail

DURATION="${DURATION:-3s}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-16}"
OUT="${OUT:-/tmp/akamata-router-bench.csv}"

printf '%s\n' 'router,routes,kind,middleware,rps,p50,p95,p99,rss_kb,binary_bytes,startup_ms' > "$OUT"

run_one() {
  local router="$1" routes="$2" kind="$3" middleware="$4"
  zig build router-bench -Doptimize=ReleaseFast \
    -Dbench-router="$router" -Dbench-routes="$routes" \
    -Dbench-route-kind="$kind" -Dbench-middlewares="$middleware"
  local binary_bytes
  binary_bytes="$(stat -f '%z' zig-out/bin/router-bench)"
  local started ready now startup_ms
  started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  ./zig-out/bin/router-bench >/tmp/akamata-router-bench-server.log 2>&1 &
  local server_pid=$!
  trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' RETURN
  local target_index=$((routes - 1)) path
  case "$kind" in
    static) path="/r/$target_index" ;;
    parameter) path="/r/$target_index/42" ;;
    wildcard) path="/r/$target_index/rest/of/path" ;;
  esac
  ready=0
  for _ in $(seq 1 500); do
    if curl -sS "http://127.0.0.1:8090$path" >/dev/null 2>&1; then ready=1; break; fi
  done
  if [[ "$ready" != 1 ]]; then
    cat /tmp/akamata-router-bench-server.log >&2
    return 1
  fi
  now="$(python3 -c 'import time; print(time.monotonic_ns())')"
  startup_ms=$(((now - started) / 1000000))
  local rss output rps p50 p95 p99
  rss="$(ps -o rss= -p "$server_pid" | tr -d ' ')"
  output="$(oha -z "$DURATION" -c "$CONNECTIONS" --no-tui --output-format json "http://127.0.0.1:8090$path")"
  rps="$(jq -r '.metrics.requests_per_sec' <<<"$output")"
  p50="$(jq -r '.metrics.latency_ms.p50' <<<"$output")ms"
  p95="$(jq -r '.metrics.latency_ms.p95' <<<"$output")ms"
  p99="$(jq -r '.metrics.latency_ms.p99' <<<"$output")ms"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$router" "$routes" "$kind" "$middleware" "$rps" "$p50" "$p95" "$p99" \
    "$rss" "$binary_bytes" "$startup_ms" | tee -a "$OUT"
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  trap - RETURN
}

# Full route-count scaling on static paths, route-shape scaling at 100 routes,
# and middleware scaling at 100 routes. This avoids redundant cross-products
# while covering every requested dimension for both implementations.
for router in ${ROUTERS:-runtime static}; do
  for routes in ${ROUTE_COUNTS:-1 10 100 500}; do run_one "$router" "$routes" static 0; done
  for kind in ${EXTRA_KINDS:-parameter wildcard}; do run_one "$router" 100 "$kind" 0; done
  for middleware in ${EXTRA_MIDDLEWARES:-3 6}; do run_one "$router" 100 static "$middleware"; done
done

printf 'wrote %s\n' "$OUT"
