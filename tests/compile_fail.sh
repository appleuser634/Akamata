#!/usr/bin/env bash
set -euo pipefail

run_case() {
  local name="$1" expected="$2" output
  if output="$(zig test --dep akamata -Mroot="tests/compile_fail/$name.zig" \
      --dep build_options -Makamata=src/akamata.zig \
      -Mbuild_options=tests/compile_fail/build_options.zig \
      --cache-dir .zig-cache --global-cache-dir /tmp/akamata-compile-fail-zig-cache 2>&1)"; then
    printf 'expected %s to fail compilation\n' "$name" >&2
    return 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf 'unexpected diagnostic for %s:\n%s\n' "$name" "$output" >&2
    return 1
  fi
  printf 'ok compile-fail: %s\n' "$name"
}

run_case duplicate_routes 'duplicate endpoint in contract graph'
run_case ambiguous_routes 'ambiguous endpoint in contract graph'
run_case duplicate_operation_id 'duplicate operation_id in contract graph'
run_case invalid_wildcard 'wildcard must be the final path segment'
run_case missing_path_input 'is not present in route'
run_case duplicate_json_body 'duplicate typed input `body`'
run_case incomplete_error_map 'missing HTTP mapping for handler error Unavailable'
run_case unsupported_capability 'target workers does not provide it'
run_case di_missing 'missing dependency provider'
run_case di_cycle 'dependency cycle includes'
run_case native_r2_binding 'target native does not provide it'
run_case untagged_protocol 'realtime protocols must be tagged unions'
run_case unsupported_db_bind 'Value.fromAny: only [N]u8 arrays are supported'
