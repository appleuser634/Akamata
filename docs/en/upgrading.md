# Upgrading from v0.0.1

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
`trust_proxy_headers = true` only when the application cannot be reached except
through a trusted proxy that overwrites client-supplied forwarding headers.
Default 500 JSON intentionally omits the internal Zig error name; log details
server-side or use a custom `onError` handler where appropriate.

## Input and generated API descriptions

`c.input(T)` now treats every non-optional field without a default as required,
whether or not `__schema.validates` contains a `required` rule. Make fields
optional or give them defaults for partial updates.

OpenAPI and client generation now includes ordinary `get`, `post`, and other
untyped routes. Use `endpoint()` when reflected request/response/query schemas
are needed. Expect the generated path set to grow; the Zig client target is
still a generated stub rather than a complete transport implementation.

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
