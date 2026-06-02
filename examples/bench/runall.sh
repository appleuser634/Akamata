#!/usr/bin/env bash
# Run all three servers (akamata, go, hono on bun) against the same scenarios.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="$ROOT/examples/bench/run.sh"
OUTDIR="${OUTDIR:-/tmp/yt-bench}"
mkdir -p "$OUTDIR"
LABEL="${LABEL:-baseline}"

stop_pid() {
  local pid="$1"
  [ -z "${pid:-}" ] && return
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  kill -9 "$pid" 2>/dev/null || true
}

run_one() {
  local label="$1"; local port="$2"; local scn="$3"
  local f="$OUTDIR/${LABEL}-${label}-${scn}.txt"
  "$RUN" "$label" "$port" "$scn" 2>&1 | tee "$f"
}

echo "==== Benchmarking label=$LABEL into $OUTDIR ===="

# 1) akamata
YT_LOG="$OUTDIR/${LABEL}-akamata.log"
"$ROOT/zig-out/bin/bench" >"$YT_LOG" 2>&1 &
YT_PID=$!
echo "-- akamata pid=$YT_PID on :8080"
sleep 1
run_one akamata 8080 hello
run_one akamata 8080 echo
run_one akamata 8080 db
stop_pid "$YT_PID"
sleep 1

# 2) go
GO_LOG="$OUTDIR/${LABEL}-go.log"
/tmp/yt-bench-go >"$GO_LOG" 2>&1 &
GO_PID=$!
echo "-- go pid=$GO_PID on :8081"
sleep 1
run_one go 8081 hello
run_one go 8081 echo
run_one go 8081 db
stop_pid "$GO_PID"
sleep 1

# 3) hono on bun
BUN_LOG="$OUTDIR/${LABEL}-hono.log"
( cd "$ROOT/examples/bench/hono" && exec bun run index.ts ) >"$BUN_LOG" 2>&1 &
BUN_PID=$!
echo "-- hono pid=$BUN_PID on :8082"
sleep 2
run_one hono 8082 hello
run_one hono 8082 echo
run_one hono 8082 db
stop_pid "$BUN_PID"

echo "==== Done. Files in $OUTDIR ===="
ls -1 "$OUTDIR" | grep "^${LABEL}-" | sort
