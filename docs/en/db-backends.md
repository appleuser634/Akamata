# DB backend

`am.db.Db` is a vtable abstraction. The same handler code works in native (SQLite), Workers (D1), and Turso (libsql/Hrana).

## Common API

```zig
pub const Db = struct {
    pub fn prepare(self: Db, sql: []const u8) !Stmt
    pub fn exec(self: Db, sql: []const u8) !void
    pub fn execAll(self: Db, script: []const u8) !void   // Execute semicolon-separated statements
    pub fn close(self: Db) void
};

pub const Stmt = struct {
    pub fn bind(self: Stmt, idx: usize, v: Value) !void
    pub fn bindAll(self: Stmt, args: anytype) !void       // Bind tuple values from index 1
    pub fn step(self: Stmt) !StepResult                   // .row | .done
    pub fn fetchOne(self: Stmt, comptime T: type) !T      // Map one row to a struct
    pub fn readRow(self: Stmt, comptime T: type) !T
    pub fn columnInt/Float/Text/Blob(self: Stmt, idx) !...
    pub fn reset(self: Stmt) !void
    pub fn deinit(self: Stmt) void
};
```

## Transparent selection with URL schema

```zig
var db = try am.db.open(alloc, url);
```

| URL | Backend |
|------------------------------|------------------------|
| `file:chat.db` | SQLite (native) |
| `libsql://example.turso.io` | Turso/libsql (HTTP) |
| `https://example.turso.io` | Turso/libsql (HTTP) |
| `d1:DB` | Cloudflare D1 (Workers)|

`d1:` is valid only when the execution target is `wasm32-freestanding`. Otherwise, SQLite/Turso is selected.

### 4 combination support status

| Deploy to | DB | Support | Route |
|---|---|---|---|
| **VPS / Container (native)** | SQLite | ✅ | Directly link `file:` → `sqlite3.c` |
| **VPS / Container (native)** | Turso | ✅ | Send HTTP/1.1 directly with `libsql://` → `std.crypto.tls.Client` (no dependencies) |
| **Cloudflare Workers (wasm)** | D1 | ✅ | `d1:` → Synchronous call to D1 binding in JSPI |
| **Cloudflare Workers (wasm)** | Turso | ✅ | Via `libsql://` → `akamata_http.akamata_fetch` (Suspending fetch) |

The code on the handler side is all the same (only the URL of `am.db.open(url)` can be switched using an environment variable).

## SQLite (native)

```zig
var db = try am.db.openSqlite(alloc, "chat.db");
defer db.close();
try db.execAll(@embedFile("schema.sql"));
```

`third_party/sqlite/sqlite3.c` is linked by `build.zig` with `addCSourceFile`. `PRAGMA journal_mode=WAL; foreign_keys=ON` is enabled by default.

## Turso (libsql / Hrana v3 over HTTP)

```zig
var db = try am.db.openTurso(alloc, "libsql://your-db.turso.io", auth_token);
```

`src/db/turso.zig` speaks Hrana v3 (`POST /v3/pipeline`). Continue stateful sessions with baton tokens. The statement is converted to Hrana's execute operation and the rows are read back from `args` / `cols` JSON.

Benefits:
- Can reference **any Turso DB** from VPS/Containers
- Unlike D1, it can be called synchronously (HTTP is std.Io.net and `await` is not required)
- Standard support for multi-region read replicas

## D1 (Workers) — JSPI implementation

```zig
// am.db.open("d1:DB"), or directly:
var db = try am.db.openD1(alloc);
```

### Implementation: JavaScript Promise Integration (JSPI)

D1's JS API is async (each `prepare/bind/all` is a Promise), so it is fundamentally inconsistent with Zig's synchronization semantics. Akamata uses **JSPI** (JavaScript Promise Integration) in V8 to completely bridge this gap:

1. **JS host** (`deploy/.../worker/index.mjs`) wraps each async D1 function with `new WebAssembly.Suspending(fn)`
2. Wrap wasm entry `handle_fetch` with `WebAssembly.promising(...)`
3. On the Zig side, just call the import as normal `extern fn` — V8 parks/resume the stack

**Important — 1 statement, 1 suspend**: JSPI suspend/resume parks/resume the entire wasm call stack, which is costly even if the JS side does not do any I/O. Therefore, **actually await only `d1_run` (query execution + all row materialization)**, and make `d1_step` / `d1_column_*` synchronous import. The Zig side executes `d1_run` in a delayed manner at the first `step()`, and thereafter advances the line cursor synchronously. Now a SELECT of N rows can be done with "1 suspend" (naively wrapping `d1_step` with Suspending would result in **1 row and 1 suspend**, which would cause ~20 unnecessary stack switches on a 20-line timeline).

```js
// Excerpt: deploy/mobus/worker/index.mjs
// The only async D1 operation: bind + run materializes all rows.
d1_run: new WebAssembly.Suspending(async (h) => {
  const e = d1stmts.get(h);
  const bound = e.bindArgs.length > 0 ? e.base.bind(...e.bindArgs) : e.base;
  const out = await bound.raw({ columnNames: true });
  e.columnNames = Array.isArray(out) && out.length > 0 ? out[0] : [];
  e.rows = Array.isArray(out) && out.length > 0 ? out.slice(1) : [];
  e.cursor = 0;
  return e.rows.length;
}),
// Synchronous: advance the materialized row cursor (no suspend).
d1_step(h) {
  const e = d1stmts.get(h);
  if (!e || e.rows == null) return -1;
  if (e.cursor >= e.rows.length) { e.currentRow = null; return 0; }
  e.currentRow = e.rows[e.cursor++];
  return 1;
},
// ...
handleFetchAsync = WebAssembly.promising(exports_ref.handle_fetch);
```

```zig
// src/db/d1.zig — Zig side is a plain extern function
extern "akamata_d1" fn d1_step(stmt: i32) i32;
```

### Zero overhead

- **Zig zero code changes**: Exactly the same handler works in SQLite/Turso/D1
- **Zero code size inflation**: Unlike full-function CPS transformations like Asyncify (Binaryen), nothing is added to the wasm binary.
- **Zero overhead for normal execution**: Synchronous passes are normal function calls
- **The same pattern can be used for KV / R2 / Durable Objects / `fetch()`**

### Backwards compatible (for older runtimes)

Old Miniflare and wranglers that do not support JSPI do not have `WebAssembly.Suspending`. In that case, the JS host will fall back to a stub that returns a `-2` sentinel, and the Zig side will throw a `D1Error.BridgeNotImplemented`. Since it is fail-closed, it will not fail silently.

```zig
return switch (rc) {
    0 => {},
    -2 => D1Error.BridgeNotImplemented,
    else => D1Error.ExecFailed,
};
```

### Performance characteristics (D1 vs Turso vs SQLite)

| Backend | Theoretical latency for one query | Notes |
|---|---|---|
| SQLite (native) | ~10us | Same process, memory access only |
| Turso (HTTP) | 1 RTT (~10-50ms) | Inter-region raw HTTP/2 |
| D1 (JSPI / Workers) | ~5-15ms | Cloudflare internal, edge-local deployment |

JSPI's wasm stack switch once is on the order of **µs**, but resume goes through the JS microtask queue, so the number of times is effective**. If you follow the "1 statement, 1 suspend" design (`d1_run` + synchronization `d1_step` above), it will be limited to 1 query and 1 suspend, and the network round trip can be ignored. On the other hand, if you suspend each row, dozens of stack switches will be accumulated in one request, resulting in a deviation of several ms compared to the native version (Actually measured P90 ~ 20 ms). What you should measure:

1. **Cold start**: First time `handle_fetch` on `wrangler dev` (wasm instantiate + D1 connection)
2. **P50/P99 Latency**: Hit simple `SELECT 1` in a loop
3. **Throughput**: 100 simultaneous connections × 10s `INSERT` + `SELECT`
4. **Comparison with Turso**: Comparison with HTTP libsql values with the same table definition and same query

### Measurement procedure (out-of-band)

```bash
# Start a local D1 with wrangler
cd examples/mobus
wrangler d1 execute mobus --local --file=schema.sql
wrangler dev --local --port 8787

# Run wrk from another terminal
wrk -t4 -c100 -d15s --latency http://127.0.0.1:8787/api/messages

# Turso comparison
TURSO_URL=libsql://your-db.turso.io TURSO_TOKEN=... ./zig-out/bin/mobus
wrk -t4 -c100 -d15s --latency http://127.0.0.1:8080/api/messages
```

The actual value depends on the environment (for Workers, the location of CF edge, for Turso, the DB region), so as a general rule, benchmarks should be taken at your actual deployment location.

## Recommended migration workflow

Use the scaffold migration path first so schema changes remain reviewable:

1. `akamata migrate generate add_notes` creates a versioned SQL file in
   `migrations/`.
2. Edit and review the SQL, then run `akamata migrate up` in the project
   directory. The native runner applies pending files in order and records
   them in `schema_migrations`.
3. For Workers, apply the reviewed file during deployment with
   `akamata deploy --migrate=migrations/001_add_notes.sql` (or the equivalent
   `wrangler d1 migrations apply` workflow).

Fresh native scaffolds also run `am.model.migrate.diff/apply` at startup for
local development. Workers scaffolds run `migrate_once.run` on the first
request. Prefer reviewed, versioned files for production deployments.

## Advanced / low-level migration

Applications that deliberately manage their own schema can use `Db.execAll`
with native SQLite or Turso:

```zig
try db.execAll(@embedFile("schema.sql"));
```

Direct Wrangler execution is an operational escape hatch for D1, not the
default scaffold workflow:

```bash
wrangler d1 execute my_database --remote --file=migrations/001_add_notes.sql
```

Do not mix ad-hoc DDL with the versioned runner unless it is recorded in
`schema_migrations`.
