# Application building blocks

Akamata keeps the common 80% short while preserving `Db.prepare`, raw SQL,
`Request`, `Response`, and `storage.Store` as escape hatches.

## Queries and validation

```zig
const PartRow = struct { id: i64, sku: []const u8 };
var q = try am.model.Query.init(db, arena, "parts", "id, sku");
_ = try q.whereEq("active", true);
_ = try q.whereIn("category_id", category_ids);
_ = try q.orderBy("id", .desc);
const parts = try q.limit(50).offset(0).fetchAll(PartRow);

const totals = try am.db.fetchAll(TotalRow, db, arena,
    "SELECT category_id, COUNT(*) FROM parts GROUP BY category_id", .{});
try Parts.updateFields(db, arena, id, .{ .name = input.name, .price = input.price });
const loaded = try am.model.preload.belongsTo(Part, "category", parts, db, arena);
```

The builder deliberately supports only equality, `IN`, ordering and paging.
Use raw SQL for joins, OR expressions, aggregates and database-specific work.
Choose the smallest layer that fits the query:

- `Repo(Model)` for primary-key CRUD and `updateFields` partial updates;
- `Query` for one-table filters, ordering, and pagination;
- `preload.belongsTo` for a conventional foreign key without N+1 queries;
- `am.db.fetchAll(DTO, ...)` for aggregates, projections, and raw SQL mapped
  into a purpose-built DTO;
- `Db.prepare` for conditional binding, complex joins, CTEs, window functions,
  inventory allocation, authorization predicates, or other business SQL.

For example, a parts screen can use `Query` for its page and
`preload.belongsTo` for categories, while stock reservation remains an
explicit constraint-backed statement. Akamata maps rows but does not hide the
business transaction or pretend D1 provides transactions.

Byte strings bind consistently on SQLite and D1: `[N]u8`, `*[N]u8`, `[]u8`,
and `[]const u8` are TEXT values containing all N bytes. Use an explicit
`am.db.Value{ .blob = bytes }` for BLOB semantics. Other array/slice element
types fail at compile time instead of being coerced.
Handlers can use `(try c.validatedJson(Input)) orelse return`; validation is
available to any DTO with `__schema.validates`, not only persisted models.
Errors use `{ "error_kind": "validation", "errors": [...] }` with HTTP 422.

## Security and sessions

`am.crypto` provides portable random bytes/hex, SHA-256/hex, timing-safe
comparison and same-origin comparison. Workers extern imports stay internal.
Sessions provide signed Secure/HttpOnly/SameSite cookies, lookup, rotation,
destroy and `revoke(c)`. CSRF can additionally enforce `Origin`,
`Sec-Fetch-Site`, and a session-bound token hash:

```zig
_ = try app.use(am.mw.csrf(State, .{
    .expected_origin = "https://parts.example",
    .bind_to_session = true,
}));
```

For tenant-specific hosts, set `.origin_verifier = am.mw.csrfOriginMatchesHost`
or provide a proxy-aware custom verifier. `.session_verifier` connects the
token hash to an application-owned database session. These hooks supplement
the double-submit and Fetch Metadata checks; they do not disable them.

Register `try app.onError(am.errors.defaultHandler(State));` for the standard
400/401/403/404/409/422/500 mapping, or register an application handler.

## Config, storage, tests and operations

`am.config.load(Config, allocator)` loads strings, integers, booleans, enums,
optionals and defaults. `Config.__config.names` maps fields to environment
names and `secrets` marks values that tooling must never print.
`am.StorageFactory` selects native filesystem or Workers R2 at compile time
and returns the same `am.storage.Store` interface.

The test client adds `.json`, `.csrf`, `.multipart`, `CookieJar`,
`expectStatus`, and `expectHeader`. Use in-memory SQLite and versioned
migrations in test setup. `Db.ping()` implements a portable health check;
static files and secure default headers remain `am.mw.serveStatic` and
`am.mw.secureHeaders`.

Typed management commands use `am.management.Command(Context)` and
`am.management.run`. `am.idempotency.claim` uses a single atomic
`INSERT ... ON CONFLICT` plus hash comparison.

## D1 atomic workflows

D1 transactions remain unsupported and `Db.begin()` fails closed. Prefer:

- one statement with constraints and `RETURNING`;
- a trigger when multiple table mutations must share one SQLite statement;
- `Db.batch` for independent operations, without claiming transactionality;
- a unique idempotency key and request hash for retried workflows;
- versioned, small and repeatable migrations.

Akamata does not emulate transactions across JSPI calls.
