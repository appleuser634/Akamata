#!/usr/bin/env bash
# Wrap resources.sh around all 7 bench servers. Emit a JSON array.
#
# Total runtime: ~3 minutes (3 scenarios × 10s wrk × 7 servers + overhead).

set -uo pipefail

AKAMATA="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$AKAMATA/examples/bench/resources.sh"

cat > /tmp/wrk_echo.lua <<'LUA'
wrk.method = "POST"
wrk.body   = '{"name":"x","n":42}'
wrk.headers["content-type"] = "application/json"
LUA
cat > /tmp/wrk_db.lua <<'LUA'
math.randomseed(os.time())
request = function() return wrk.format("GET", "/db/" .. tostring(math.random(1,3))) end
LUA

# Cleanup leftovers
pkill -9 -f "zig-out/bin/bench" 2>/dev/null
pkill -9 -f "yt-bench-go" 2>/dev/null
pkill -9 -f "yt-bench-rust" 2>/dev/null
pkill -9 -f "bun.*index.ts" 2>/dev/null
pkill -9 -f "fastify/index.mjs" 2>/dev/null
sleep 1

out=/tmp/bench_resources.json
echo "[" > "$out"

emit() {
  local sep="$1"; local body="$2"
  echo "$sep" >> "$out"
  echo "$body" >> "$out"
}

run() {
  local sep="$1"
  shift
  emit "$sep" "$("$SCRIPT" "$@")"
}

run "" "akamata-threaded" "$AKAMATA/zig-out/bin/bench" "8080" "zig-out/bin/bench"
run "," "akamata-reactor" "BENCH_RUNTIME=reactor $AKAMATA/zig-out/bin/bench" "8080" "zig-out/bin/bench"
run "," "go-nethttp" "/tmp/yt-bench-go" "8081" "yt-bench-go"
run "," "rust-axum" "$AKAMATA/examples/bench/rust/target/release/yt-bench-rust" "8083" "yt-bench-rust"
run "," "bun-raw" "cd $AKAMATA/examples/bench/bun_raw && bun run index.ts" "8084" "bun_raw/index.ts"
run "," "hono-bun" "cd $AKAMATA/examples/bench/hono && bun run index.ts" "8082" "hono/index.ts"
run "," "fastify-node" "cd $AKAMATA/examples/bench/fastify && node index.mjs" "8085" "fastify/index.mjs"

echo "]" >> "$out"
echo
echo "Wrote $out"
