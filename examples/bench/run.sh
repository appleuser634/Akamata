#!/usr/bin/env bash
# Run a single wrk scenario against a server already listening on PORT.
# Usage: ./run.sh <name> <port> <scenario>
#   scenario: hello | echo | db
set -euo pipefail

NAME="${1:-akamata}"
PORT="${2:-8080}"
SCN="${3:-hello}"

THREADS="${THREADS:-8}"
CONN="${CONN:-256}"
DURATION="${DURATION:-15s}"

case "$SCN" in
  hello)
    URL="http://127.0.0.1:${PORT}/hello"
    EXTRA=""
    ;;
  echo)
    URL="http://127.0.0.1:${PORT}/echo"
    cat > /tmp/yt_echo.lua <<'EOF'
wrk.method = "POST"
wrk.body = '{"name":"alice","n":42}'
wrk.headers["Content-Type"] = "application/json"
EOF
    EXTRA="-s /tmp/yt_echo.lua"
    ;;
  db)
    URL="http://127.0.0.1:${PORT}/db/2"
    EXTRA=""
    ;;
  *)
    echo "unknown scenario: $SCN" >&2; exit 2;;
esac

echo "==> $NAME / $SCN @ $URL  (threads=$THREADS, conn=$CONN, dur=$DURATION)"
wrk -t"$THREADS" -c"$CONN" -d"$DURATION" --latency $EXTRA "$URL"
