#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: scaffold_smoke.sh /path/to/akamata" >&2
  exit 2
fi

cli=$1
case "$cli" in
  /*) ;;
  *) cli="$(cd "$(dirname "$cli")" && pwd)/$(basename "$cli")" ;;
esac
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/akamata-scaffold-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

cd "$tmp_dir"
"$cli" init smokeapp --target=both
cd smokeapp

test ! -e ../Akamata
if grep -F '../Akamata' build.zig.zon >/dev/null; then
  echo "generated build.zig.zon still depends on ../Akamata" >&2
  exit 1
fi
grep -F '.url = "https://github.com/appleuser634/Akamata/archive/' build.zig.zon >/dev/null
grep -F '.hash = "akamata-' build.zig.zon >/dev/null
grep -F 'l === 0 ? new Uint8Array(0)' deploy/worker/index.mjs >/dev/null
grep -F 'if (b.length > 0) new Uint8Array(memory.buffer' deploy/worker/index.mjs >/dev/null
grep -F 'wasmDispatchQueue.run(() => dispatchWasm(request))' deploy/worker/index.mjs >/dev/null

zig build
zig build -Dbackend=workers -Doptimize=ReleaseSmall
"$cli" migrate up
"$cli" migrate generate create_smoke
migration_file=$(find migrations -type f -name '*_create_smoke.sql' -print | head -n 1)
test -n "$migration_file"
printf '%s\n' 'CREATE TABLE IF NOT EXISTS smoke_items (id INTEGER PRIMARY KEY);' >> "$migration_file"
"$cli" migrate up
"$cli" migrate up

echo "scaffold smoke test: OK"
