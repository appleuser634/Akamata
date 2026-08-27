# Upgrading from v0.0.1

## Updating the framework and generated files

Use the CLI that ships with the target Akamata release. Updating only
`build.zig.zon` is insufficient for Workers projects because the generated
JavaScript bridge is part of the framework/runtime ABI.

```bash
akamata update --to=v0.1.1 --sync
```

`akamata update` detects the pinned `.akamata` release, resolves the target
archive hash, rewrites only that dependency's URL/hash, and validates a Native
build plus a Workers build when a Wrangler config is present. With no `--to`,
it selects the latest stable release bundled with that CLI. `--dry-run` prints
planned changes without writing or building.

`akamata sync` manages only files recorded in `.akamata/managed-files.json`:

- `deploy/worker/index.mjs`
- `deploy/worker/wasm_dispatch.mjs`
- `deploy/worker/internal_routes.mjs`
- `deploy/worker/realtime_object.mjs`

Application source, `build.zig`, and `wrangler.toml` are user-owned and never
rewritten. If a managed file's SHA-256 differs from its generation hash, sync
shows a diff summary and refuses by default. `--force` saves a `.bak` before
replacement. Pre-manifest v0.1.0 glue migrates only when it exactly matches the
official normalized v0.1.0 template.

```bash
akamata update --to=v0.1.1 --sync --dry-run
akamata update --to=v0.1.1 --sync
git diff
```

This page covers behavior changes on `main` after v0.0.1. Run the full test
suite before deployment; several changes intentionally turn previously
accepted ambiguous states into startup or request errors.

## Routes and groups

Complete route and middleware registration before `prepare()`, the first test
client dispatch, or `serve()`. Registration is frozen afterward. Duplicate or
equivalent paths, ambiguous dynamic shapes, duplicate parameter names,
non-terminal wildcards, and more than 16 captures now fail registration.

`basePath()` now returns a lightweight `Group` value. Existing inferred code
usually needs no change:

```zig
var api = try app.basePath("/api");
_ = try api.get("/users", listUsers);
```

Do not declare it as `*App` or deinitialize it. The parent owns its prefixes,
routes, middleware resources, session store, and rate-limiter allocations.

Account for standard HTTP semantics in assertions and clients: `HEAD` may use
`GET`, body bytes are suppressed, and a method mismatch is `405` with `Allow`
instead of `404`.

## Proxy trust and errors

Forwarding headers no longer affect `c.req.ip()` by default. Set
`trust_proxy_headers = true` and provide `trusted_proxy_fn` only when the
application cannot be reached except through a trusted proxy that overwrites
client-supplied forwarding headers.
Default 500 JSON intentionally omits the internal Zig error name; log details
server-side or use a custom `onError` handler where appropriate.

## Input and generated API descriptions

`c.input(T)` now treats every non-optional field without a default as required,
whether or not `__schema.validates` contains a `required` rule. Make fields
optional or give them defaults for partial updates.

OpenAPI and client generation now includes ordinary `get`, `post`, and other
untyped routes. Use `endpoint()` when reflected request/response/query schemas
are needed. Expect the generated path set to grow. The incomplete Zig client
target now fails generation with `error.UnsupportedTarget` instead of emitting
methods that panic at runtime.

## Database and migrations

Optional repository fields now distinguish SQL `NULL` from zero, `false`, and
empty text through `Stmt.columnIsNull()`. Audit workarounds that compensated for
the previous coercion.

SQLite sends `execAll()` scripts to SQLite's parser. Portable backends split on
statement terminators while respecting quotes and comments and reject malformed
scripts. Each versioned migration is atomic on SQLite and Turso, including its
`schema_migrations` record. D1 remains non-transactional through this bridge;
keep D1 migrations small and idempotent.

## Suggested verification

Run `zig build test`, `zig build integration`, and `zig build tasks-test`, then
build every deployment target you use. Also test duplicate-route startup,
missing required input, `HEAD`/`405`, proxy IP behavior, nullable model fields,
and a deliberately failing migration.
