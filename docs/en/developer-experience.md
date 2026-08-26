# Developer experience

Akamata keeps route knowledge in Zig values so the compiler, runtime, OpenAPI generator, client generator, and tests can share it. The development tools on this page are available in v0.1.0.

## Endpoint contracts and typed inputs

Declare an endpoint once and register the declaration:

```zig
const GetNote = am.contract.Endpoint(.GET, "/notes/:id", showNote, .{
    .response = Note,
    .summary = "Fetch a note",
    .operation_id = "getNote",
});

try GetNote.register(app);
```

This is the same metadata consumed by OpenAPI and generated clients. Typed source wrappers avoid repeating parsing rules:

```zig
const id = try am.contract.Path(i64, "id").read(c);
const page = try am.contract.Query(u32, "page").read(c);
const token = try am.contract.Header([]const u8, "authorization").read(c);
const session = try am.contract.Cookie([]const u8, "session").read(c);
const body = try am.contract.Json(CreateNote).read(c);
```

Supported scalar source types are strings, booleans, integers, and floats. JSON accepts any type supported by Akamata's JSON parser.

## Typed dependencies and capabilities

`am.di.Registry(&.{ Database, Mailer })` stores caller-owned pointers with compile-time type lookup and no hash lookup or allocation. `am.di.Provider` plus `am.di.validate` checks duplicate providers, missing dependencies, and application-to-request scope violations at compile time.

Libraries can publish an `am.capability.Set`. Call `am.capability.require` at comptime to reject unsupported native, Workers, or container combinations before deployment. Filesystem- and thread-dependent packages are rejected for Workers.

## Project CLI

```console
akamata inspect             # targets, migrations, and environment summary
akamata inspect --json      # stable machine-readable summary
akamata check --quick       # structural validation
akamata check               # validation plus zig build test
akamata generate resource note title:[]const\ u8 published:bool
akamata generate resource note --pretend
akamata destroy resource note --force
akamata api diff old-openapi.json new-openapi.json
```

Use [`akamata client`](cli-client.md) with no arguments for the full-screen endpoint explorer, with request arguments for direct HTTP calls, and `akamata api call` for OpenAPI operation-driven calls. Generated applications expose route metadata to local tooling through the non-HTTP `akamata-openapi` runner mode.

The resource generator creates a model/repository, typed list/create handlers with OpenAPI contracts, a factory test, and a timestamped migration. It deliberately does not edit route wiring: instantiate `Resource.Routes(State)` and call `register` explicitly. Destroy removes generated source files but retains migrations to avoid accidental data loss.

`api diff` fails when a path or HTTP operation is removed and also detects removed schemas/properties, type changes, and newly required properties.

## Migrations

New migration files contain `-- migrate:up` and `-- migrate:down` sections.

```console
akamata migrate plan
akamata migrate status
akamata migrate up
akamata migrate rollback
akamata migrate redo
```

Rollback refuses files without non-empty down SQL. Commands delegate to the generated application runner so they use the same database configuration as the app.

## Diagnostics and contract tests

`am.diagnostics.Diagnostic` provides stable codes, severity, hints, source files, and text/JSON renderers. Application tests can enforce contract completeness:

```zig
const audit = try am.testing.auditContracts(&app, arena);
try std.testing.expect(audit.ok());
```

The audit reports untyped routes and duplicate non-empty operation IDs. `am.testing.factory` now starts from deterministic zeroed storage before applying schema defaults and overrides; required pointer and slice fields should still be supplied by the test.

## Typed handlers, lifecycle, and budgets

`contract.Bound` generates request extraction from an input struct at comptime and adapts it to the regular handler ABI without runtime reflection. Fields use `Path`, `Query`, `Header`, `Cookie`, or `Json` and expose parsed values through `.value`.

Register one-time setup and teardown with `app.lifecycle(.{ .startup = startup, .shutdown = shutdown })`. Endpoint specs accept `limits` for request/response bytes, timeout, DB queries, outbound requests, and streaming. Non-streaming budgets are enforced from request-scoped counters and timing; all fields are emitted as `x-akamata-limits`.

Call `comptime am.contract.validateGraph(.{ List, Create, Show });` in a route module to reject duplicate method/path pairs and operation IDs before application initialization.

`am.testing.DatabaseSandbox` rolls database tests back unless explicitly committed. `malformedJsonCorpus` supplies deterministic contract-fuzzing seeds.

## Route and project inspection

```console
akamata routes [--json]
akamata routes explain GET /notes/{id}
akamata doctor [--json]
akamata config <show|check>
akamata test [--watch]
akamata runner <command> [args]
```

Routes prefer the non-HTTP inspection runner and safely fall back to literal source registrations for older applications and repository examples. `routes explain` includes operation metadata, the effective middleware chain, and declared budgets when contract metadata is available. Configuration output reveals keys and presence only, never values. Doctor checks project manifests, the entry point, deployment files, and migrations. Test wraps the project test command, while runner delegates to the generated application's typed management-command protocol; new projects include a `db-check` example.
