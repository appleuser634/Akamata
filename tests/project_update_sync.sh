#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: project_update_sync.sh /path/to/akamata" >&2
  exit 2
fi

cli=$1
case "$cli" in
  /*) ;;
  *) cli="$(cd "$(dirname "$cli")" && pwd)/$(basename "$cli")" ;;
esac
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
cmp "$repo_dir/deploy/worker/wasm_dispatch.mjs" "$repo_dir/tools/akamata/src/templates/wasm_dispatch.mjs.tpl"
cmp "$repo_dir/deploy/worker/internal_routes.mjs" "$repo_dir/tools/akamata/src/templates/internal_routes.mjs.tpl"
cmp "$repo_dir/deploy/worker/realtime_object.mjs" "$repo_dir/tools/akamata/src/templates/realtime_object.mjs.tpl"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/akamata-update-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

cd "$tmp_dir"
"$cli" init legacyapp --target=both
cd legacyapp

printf '%s\n' '# user-owned-wrangler-setting' >> deploy/wrangler.toml
printf '%s\n' '// user-owned-source-marker' >> src/main.zig

# Model an unmodified v0.1.0 project, before manifests and serialization.
sed 's/{{NAME}}/legacyapp/g' "$repo_dir/tests/fixtures/v0.1.0_worker_index.mjs.tpl" > deploy/worker/index.mjs
rm -f deploy/worker/wasm_dispatch.mjs deploy/worker/internal_routes.mjs deploy/worker/realtime_object.mjs
rm -f .akamata/managed-files.json
sed \
  -e 's#moribit/Akamata/archive/refs/tags/v0.1.2#appleuser634/Akamata/archive/refs/tags/v0.1.0#' \
  -e 's#akamata-0.1.2-uJIoI3FOLAEWewAl6QsxLEl6mh23e9qKnWLlEWP3_quG#akamata-0.1.0-uJIoI4fvKwH--xMKwulRpDc6xEEUfaP0oilU6-dfUqbw#' \
  build.zig.zon > build.zig.zon.old
mv build.zig.zon.old build.zig.zon

before_zon=$(shasum -a 256 build.zig.zon)
before_glue=$(shasum -a 256 deploy/worker/index.mjs)
dry_output=$("$cli" update --to=v0.1.2 --sync --dry-run 2>&1)
printf '%s\n' "$dry_output" | grep -F 'would update build.zig.zon' >/dev/null
printf '%s\n' "$dry_output" | grep -F 'would update deploy/worker/index.mjs' >/dev/null
test "$before_zon" = "$(shasum -a 256 build.zig.zon)"
test "$before_glue" = "$(shasum -a 256 deploy/worker/index.mjs)"
test ! -e deploy/worker/wasm_dispatch.mjs

"$cli" update --to=v0.1.2 --sync
grep -F 'refs/tags/v0.1.2.tar.gz' build.zig.zon >/dev/null
grep -F 'wasmDispatchQueue.run(() => dispatchWasm(request))' deploy/worker/index.mjs >/dev/null
grep -F 'await previous' deploy/worker/wasm_dispatch.mjs >/dev/null
test -f deploy/worker/internal_routes.mjs
test -f deploy/worker/realtime_object.mjs
test -f .akamata/managed-files.json
grep -F '# user-owned-wrangler-setting' deploy/wrangler.toml >/dev/null
grep -F '// user-owned-source-marker' src/main.zig >/dev/null

printf '%s\n' '// local glue customization' >> deploy/worker/index.mjs
rm deploy/worker/wasm_dispatch.mjs
edited=$(shasum -a 256 deploy/worker/index.mjs)
if "$cli" sync >sync-refused.log 2>&1; then
  echo "sync unexpectedly overwrote a locally modified managed file" >&2
  exit 1
fi
grep -F 'REFUSED: local changes detected' sync-refused.log >/dev/null
test "$edited" = "$(shasum -a 256 deploy/worker/index.mjs)"
test ! -e deploy/worker/wasm_dispatch.mjs

"$cli" sync --force
grep -F '// local glue customization' deploy/worker/index.mjs.bak >/dev/null
if grep -F '// local glue customization' deploy/worker/index.mjs >/dev/null; then
  echo "forced sync did not restore framework glue" >&2
  exit 1
fi
test -f deploy/worker/wasm_dispatch.mjs
grep -F '# user-owned-wrangler-setting' deploy/wrangler.toml >/dev/null
grep -F '// user-owned-source-marker' src/main.zig >/dev/null

zig build
zig build -Dbackend=workers -Doptimize=ReleaseSmall
echo "project update/sync regression test: OK"
