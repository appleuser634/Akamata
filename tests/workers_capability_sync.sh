#!/bin/sh
set -eu

cli=$1
case "$cli" in /*) ;; *) cli="$(cd "$(dirname "$cli")" && pwd)/$(basename "$cli")" ;; esac
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/akamata-capability-sync.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

run_case() {
  name=$1
  shift
  cd "$tmp_dir"
  "$cli" init "$name" --target=workers "$@"
  cd "$name"

  # Model a manifest-before project whose old generated entry is a known
  # Akamata template. Its selected bindings remain user-owned in wrangler.
  sed "s/{{NAME}}/$name/g" "$repo_dir/tests/fixtures/v0.1.0_worker_index.mjs.tpl" > deploy/worker/index.mjs
  rm -f deploy/worker/wasm_dispatch.mjs deploy/worker/internal_routes.mjs deploy/worker/realtime_object.mjs .akamata/managed-files.json

  dry=$("$cli" sync --dry-run 2>&1)
  printf '%s\n' "$dry" | grep -F 'capabilities:' >/dev/null
  printf '%s\n' "$dry" | grep -F 'would update deploy/worker/index.mjs' >/dev/null
  test ! -e .akamata/managed-files.json
  "$cli" sync

  # All modern glue keeps the request framing fix and serialized ABI boundary.
  grep -F 'if (lower === "host" || lower === "content-length") continue' deploy/worker/index.mjs >/dev/null
  grep -F 'dispatchWasmUnlocked(request)' deploy/worker/index.mjs >/dev/null
  zig build -Dbackend=workers -Doptimize=ReleaseSmall
}

run_case d1_only --d1
d1_dry=$("$cli" sync --dry-run 2>&1)
printf '%s\n' "$d1_dry" | grep -F 'D1=keep, R2=disabled, Queue=disabled, Realtime=disabled' >/dev/null
test ! -e deploy/worker/realtime_object.mjs

run_case d1_r2 --d1 --r2
grep -F 'akamata_r2_put_begin' deploy/worker/index.mjs >/dev/null
grep -F 'akamata_r2_get_begin' deploy/worker/index.mjs >/dev/null
grep -F 'binding = "FILES"' deploy/wrangler.toml >/dev/null
# mimoc-parts contract: the generated Workers module and JS import namespace
# jointly expose am.storage.Store -> Workers R2.
printf '%s\n' 'comptime { _ = am.platform.workers.R2Store; _ = am.storage.Store; }' >> src/worker.zig
zig build -Dbackend=workers -Doptimize=ReleaseSmall

run_case queue_only --queue
grep -F 'async queue(batch, env)' deploy/worker/index.mjs >/dev/null
grep -F 'akamata_queue_send' deploy/worker/index.mjs >/dev/null

run_case realtime_only --realtime
grep -F 'AkamataRealtimeApplication' deploy/worker/index.mjs >/dev/null
test -f deploy/worker/internal_routes.mjs
test -f deploy/worker/realtime_object.mjs
grep -F 'deploy/worker/realtime_object.mjs' .akamata/managed-files.json >/dev/null
# Removing the selected Realtime capability makes its formerly managed files
# explicit deletions; dry-run must report them without touching disk.
sed '/^\[\[services\]\]/,$d' deploy/wrangler.toml > deploy/wrangler.toml.no-realtime
mv deploy/wrangler.toml.no-realtime deploy/wrangler.toml
realtime_remove_dry=$("$cli" sync --dry-run 2>&1)
printf '%s\n' "$realtime_remove_dry" | grep -F 'would delete deploy/worker/realtime_object.mjs' >/dev/null
test -f deploy/worker/realtime_object.mjs
"$cli" sync
test ! -e deploy/worker/internal_routes.mjs
test ! -e deploy/worker/realtime_object.mjs
if grep -F 'realtime_object.mjs' .akamata/managed-files.json >/dev/null; then
  echo "manifest retained disabled Realtime glue" >&2
  exit 1
fi

run_case combined --d1 --r2 --queue --realtime
grep -F 'akamata_r2_put_begin' deploy/worker/index.mjs >/dev/null
grep -F 'akamata_queue_send' deploy/worker/index.mjs >/dev/null
grep -F 'AkamataRealtimeRoom' deploy/worker/index.mjs >/dev/null

echo "Workers capability sync regression test: OK"
