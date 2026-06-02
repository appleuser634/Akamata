#!/usr/bin/env bash
# Sample CPU% / RSS / threads / fds at 1 Hz while wrk hammers a server.
# Outputs both raw CSVs and a small JSON summary.
#
# Usage: resources.sh <name> <cmd> <port> <cleanup_pattern>
#
# The caller is responsible for placing /tmp/wrk_echo.lua and /tmp/wrk_db.lua
# (same scripts the regular bench uses).
#
# This script does NOT compare servers itself — see resources_all.sh for that.

set -uo pipefail

NAME="$1"
CMD="$2"
PORT="$3"
CLEANUP="$4"

OUTDIR=${OUTDIR:-/tmp/yt-bench-res}
mkdir -p "$OUTDIR"

# Start server
eval "$CMD" >/tmp/${NAME}.startup.log 2>&1 &
PID=$!

# Wait until reachable
for i in $(seq 1 100); do
  if curl -fsS --max-time 0.5 "http://127.0.0.1:${PORT}/hello" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

# Real PID may differ when CMD starts a subshell. Resolve via the listening port.
LPID=$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $2; exit}')
if [ -n "$LPID" ]; then PID="$LPID"; fi

# Idle measurement (give it a beat to settle)
sleep 1
IDLE_RSS_KB=$(ps -o rss= -p $PID 2>/dev/null | tr -d ' ')
IDLE_CPU=$(ps -o %cpu= -p $PID 2>/dev/null | tr -d ' ')
IDLE_THREADS=$(ps -M -p $PID 2>/dev/null | wc -l | tr -d ' ')
[ -n "$IDLE_THREADS" ] && IDLE_THREADS=$((IDLE_THREADS - 1)) # subtract header
IDLE_FDS=$(lsof -p $PID 2>/dev/null | wc -l | tr -d ' ')
[ -n "$IDLE_FDS" ] && IDLE_FDS=$((IDLE_FDS - 1))

# Sampler runs while wrk runs. Drop into a file, then summarise.
csv="$OUTDIR/${NAME}.csv"
echo "ts,rss_kb,cpu_pct,threads,fds" > "$csv"
sampler_pid=
sample_loop() {
  local scenario="$1"
  while true; do
    local rss cpu thr fds
    rss=$(ps -o rss= -p $PID 2>/dev/null | tr -d ' ')
    cpu=$(ps -o %cpu= -p $PID 2>/dev/null | tr -d ' ')
    thr=$(ps -M -p $PID 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$thr" ] && thr=$((thr - 1))
    fds=$(lsof -p $PID 2>/dev/null | wc -l | tr -d ' ')
    [ -n "$fds" ] && fds=$((fds - 1))
    if [ -z "$rss" ]; then break; fi
    echo "$(date +%s),${rss},${cpu},${thr},${fds},${scenario}" >> "$csv"
    sleep 1
  done
}

# Run wrk for each scenario with a sampler in parallel
run_one() {
  local label="$1"; local url_path="$2"; local script="$3"
  sample_loop "$label" &
  sampler_pid=$!
  if [ -n "$script" ]; then
    wrk -t8 -c256 -d10s -s "$script" "http://127.0.0.1:${PORT}${url_path}" >/dev/null 2>&1
  else
    wrk -t8 -c256 -d10s "http://127.0.0.1:${PORT}${url_path}" >/dev/null 2>&1
  fi
  kill $sampler_pid 2>/dev/null
  wait $sampler_pid 2>/dev/null
  sleep 1
}

run_one "hello" "/hello" ""
run_one "echo" "/echo" "/tmp/wrk_echo.lua"
run_one "db" "/db" "/tmp/wrk_db.lua"

# Aggregate per-scenario averages
agg() {
  local s="$1"
  awk -F',' -v s="$s" '
    BEGIN { rss_max=0; rss_sum=0; cpu_max=0; cpu_sum=0; thr_max=0; thr_sum=0; fds_max=0; fds_sum=0; n=0 }
    $6 == s {
      n++
      rss_sum+=$2; if ($2>rss_max) rss_max=$2
      cpu_sum+=$3; if ($3+0>cpu_max+0) cpu_max=$3
      thr_sum+=$4; if ($4>thr_max) thr_max=$4
      fds_sum+=$5; if ($5>fds_max) fds_max=$5
    }
    END {
      if (n==0) { print "0,0,0,0,0,0,0,0"; exit }
      printf "%d,%d,%.1f,%.1f,%d,%.1f,%d,%.1f\n",
        rss_max, rss_sum/n, cpu_max, cpu_sum/n, thr_max, thr_sum/n, fds_max, fds_sum/n
    }
  ' "$csv"
}

H=$(agg hello)
E=$(agg echo)
D=$(agg db)

cat <<EOF
{
  "name": "$NAME",
  "pid": $PID,
  "idle": { "rss_kb": $IDLE_RSS_KB, "cpu_pct": "$IDLE_CPU", "threads": $IDLE_THREADS, "fds": $IDLE_FDS },
  "hello": { "rss_kb_max": $(echo $H | cut -d, -f1), "rss_kb_avg": $(echo $H | cut -d, -f2), "cpu_pct_max": $(echo $H | cut -d, -f3), "cpu_pct_avg": $(echo $H | cut -d, -f4), "threads_max": $(echo $H | cut -d, -f5), "threads_avg": $(echo $H | cut -d, -f6), "fds_max": $(echo $H | cut -d, -f7), "fds_avg": $(echo $H | cut -d, -f8) },
  "echo":  { "rss_kb_max": $(echo $E | cut -d, -f1), "rss_kb_avg": $(echo $E | cut -d, -f2), "cpu_pct_max": $(echo $E | cut -d, -f3), "cpu_pct_avg": $(echo $E | cut -d, -f4), "threads_max": $(echo $E | cut -d, -f5), "threads_avg": $(echo $E | cut -d, -f6), "fds_max": $(echo $E | cut -d, -f7), "fds_avg": $(echo $E | cut -d, -f8) },
  "db":    { "rss_kb_max": $(echo $D | cut -d, -f1), "rss_kb_avg": $(echo $D | cut -d, -f2), "cpu_pct_max": $(echo $D | cut -d, -f3), "cpu_pct_avg": $(echo $D | cut -d, -f4), "threads_max": $(echo $D | cut -d, -f5), "threads_avg": $(echo $D | cut -d, -f6), "fds_max": $(echo $D | cut -d, -f7), "fds_avg": $(echo $D | cut -d, -f8) }
}
EOF

eval "pkill -9 -f '$CLEANUP' 2>/dev/null"
sleep 0.5
