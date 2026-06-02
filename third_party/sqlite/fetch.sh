#!/usr/bin/env bash
set -euo pipefail

VERSION="3530100"
YEAR="2026"
URL="https://www.sqlite.org/${YEAR}/sqlite-amalgamation-${VERSION}.zip"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$DIR"

if [ -f sqlite3.c ] && [ -f sqlite3.h ]; then
  echo "sqlite3.c / sqlite3.h already present; skipping. Delete them and rerun to refresh."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $URL ..."
curl -fsSL -o "$tmp/sqlite.zip" "$URL"

echo "Extracting ..."
unzip -j -o "$tmp/sqlite.zip" \
  "sqlite-amalgamation-${VERSION}/sqlite3.c" \
  "sqlite-amalgamation-${VERSION}/sqlite3.h" \
  -d "$DIR"

cat > VERSION.txt <<EOF
sqlite-amalgamation-${VERSION}
source: ${URL}
EOF

echo "Done. sqlite3.c / sqlite3.h placed under $DIR"
