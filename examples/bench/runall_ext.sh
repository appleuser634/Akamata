#!/usr/bin/env bash
# Run all 6 bench servers (akamata threaded/reactor, go, rust, hono, bun raw,
# fastify) through the same 3 scenarios, capturing:
#
#   - artifact size (binary or main source)
#   - idle RSS (KB, measured 1s after startup)
#   - peak RSS (KB, measured at end of last wrk run)
#   - startup time to first 200 OK (ms)
#   - req/s + P50 + P99 for each of /hello, /echo, /db
#
# Output: /tmp/bench_results.json + a human-readable summary on stdout.

set -uo pipefail

cd "$(dirname "$0")"
AKAMATA=/Users/musashi.miyagi/Zig/Akamata

results_json=/tmp/bench_results.json
echo "[" > "$results_json"
first=1

emit_json() {
  if [ $first -eq 0 ]; then echo "," >> "$results_json"; fi
  first=0
  cat >> "$results_json"
}

# Wait for an HTTP 200 from a URL, up to 30s. Echoes the elapsed ms.
wait_ready() {
  local url="$1"
  local start_ms end_ms
  start_ms=$(python3 -c "import time;print(int(time.time()*1000))")
  for i in $(seq 1 300); do
    if curl -fsS --max-time 0.5 "$url" >/dev/null 2>&1; then
      end_ms=$(python3 -c "import time;print(int(time.time()*1000))")
      echo $((end_ms - start_ms))
      return 0
    fi
    sleep 0.1
  done
  echo -1
  return 1
}

rss_kb() {
  ps -o rss= -p "$1" 2>/dev/null | tr -d ' '
}

run_scenario() {
  local label="$1"
  local url="$2"
  local script="$3"
  if [ -n "$script" ]; then
    wrk -t8 -c256 -d10s --latency -s "$script" "$url" 2>&1
  else
    wrk -t8 -c256 -d10s --latency "$url" 2>&1
  fi
}

extract() {
  # extract "Requests/sec: N" and percentiles from wrk output
  local out="$1"
  local rps=$(echo "$out" | awk '/Requests\/sec:/ {print $2}')
  local p50=$(echo "$out" | awk '/^[[:space:]]*50%/ {print $2; exit}')
  local p99=$(echo "$out" | awk '/^[[:space:]]*99%/ {print $2; exit}')
  local err=$(echo "$out" | awk '/Non-2xx or 3xx/ {print $4; exit}')
  if [ -z "$err" ]; then err=0; fi
  echo "$rps|$p50|$p99|$err"
}

bench_one() {
  local name="$1"
  local cmd="$2"
  local port="$3"
  local artifact_size="$4"
  local cleanup_pattern="$5"

  echo "============================================"
  echo "= $name"
  echo "============================================"

  # Start server
  eval "$cmd" >/tmp/${name}.startup.log 2>&1 &
  local pid=$!
  local startup_ms
  startup_ms=$(wait_ready "http://127.0.0.1:$port/hello")
  if [ "$startup_ms" = "-1" ]; then
    echo "  FAILED to start within 30s"
    eval "pkill -9 -f '$cleanup_pattern' 2>/dev/null"
    return
  fi

  # Idle RSS (after the first GET that booted the server)
  sleep 0.3
  local idle_rss=$(rss_kb $pid)

  # 3 scenarios
  local hello_out echo_out db_out
  hello_out=$(run_scenario "/hello" "http://127.0.0.1:$port/hello" "")
  echo_out=$(run_scenario "/echo" "http://127.0.0.1:$port/echo" "/tmp/wrk_echo.lua")
  db_out=$(run_scenario "/db" "http://127.0.0.1:$port" "/tmp/wrk_db.lua")

  # Peak RSS at end
  local peak_rss=$(rss_kb $pid)

  local hello_p=$(extract "$hello_out")
  local echo_p=$(extract "$echo_out")
  local db_p=$(extract "$db_out")

  printf "  artifact:    %s\n" "$artifact_size"
  printf "  startup:     %s ms\n" "$startup_ms"
  printf "  idle RSS:    %s KB\n" "$idle_rss"
  printf "  peak RSS:    %s KB\n" "$peak_rss"
  printf "  hello rps=%s  P50=%s P99=%s err=%s\n" $(echo "$hello_p" | tr '|' ' ')
  printf "  echo  rps=%s  P50=%s P99=%s err=%s\n" $(echo "$echo_p" | tr '|' ' ')
  printf "  db    rps=%s  P50=%s P99=%s err=%s\n" $(echo "$db_p" | tr '|' ' ')

  # JSON
  emit_json <<EOF
{
  "name": "$name",
  "artifact_size": "$artifact_size",
  "startup_ms": $startup_ms,
  "idle_rss_kb": $idle_rss,
  "peak_rss_kb": $peak_rss,
  "hello": { "rps": "$(echo $hello_p | cut -d'|' -f1)", "p50": "$(echo $hello_p | cut -d'|' -f2)", "p99": "$(echo $hello_p | cut -d'|' -f3)", "err": "$(echo $hello_p | cut -d'|' -f4)" },
  "echo":  { "rps": "$(echo $echo_p  | cut -d'|' -f1)", "p50": "$(echo $echo_p  | cut -d'|' -f2)", "p99": "$(echo $echo_p  | cut -d'|' -f3)", "err": "$(echo $echo_p  | cut -d'|' -f4)" },
  "db":    { "rps": "$(echo $db_p    | cut -d'|' -f1)", "p50": "$(echo $db_p    | cut -d'|' -f2)", "p99": "$(echo $db_p    | cut -d'|' -f3)", "err": "$(echo $db_p    | cut -d'|' -f4)" }
}
EOF

  eval "pkill -9 -f '$cleanup_pattern' 2>/dev/null"
  sleep 0.5
}

# === 1. Akamata threaded ===
bench_one "akamata-threaded" \
  "$AKAMATA/zig-out/bin/bench" \
  "8080" \
  "$(stat -f%z $AKAMATA/zig-out/bin/bench) bytes" \
  "zig-out/bin/bench"

# === 2. Akamata reactor ===
bench_one "akamata-reactor" \
  "BENCH_RUNTIME=reactor $AKAMATA/zig-out/bin/bench" \
  "8080" \
  "$(stat -f%z $AKAMATA/zig-out/bin/bench) bytes" \
  "zig-out/bin/bench"

# === 3. Go net/http ===
bench_one "go-nethttp" \
  "/tmp/yt-bench-go" \
  "8081" \
  "$(stat -f%z /tmp/yt-bench-go) bytes" \
  "yt-bench-go"

# === 4. Rust Axum ===
bench_one "rust-axum" \
  "$AKAMATA/examples/bench/rust/target/release/yt-bench-rust" \
  "8083" \
  "$(stat -f%z $AKAMATA/examples/bench/rust/target/release/yt-bench-rust) bytes" \
  "yt-bench-rust"

# === 5. Bun raw ===
bench_one "bun-raw" \
  "cd $AKAMATA/examples/bench/bun_raw && bun run index.ts" \
  "8084" \
  "n/a (interpreted)" \
  "bun_raw/index.ts"

# === 6. Hono on Bun ===
bench_one "hono-bun" \
  "cd $AKAMATA/examples/bench/hono && bun run index.ts" \
  "8082" \
  "n/a (interpreted)" \
  "hono/index.ts"

# === 7. Node Fastify ===
bench_one "fastify-node" \
  "cd $AKAMATA/examples/bench/fastify && node index.mjs" \
  "8085" \
  "n/a (interpreted)" \
  "fastify/index.mjs"

echo "]" >> "$results_json"

echo
echo "=== Done. JSON saved to $results_json ==="
