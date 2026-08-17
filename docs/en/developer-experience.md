# Developer experience

Akamata keeps route knowledge in Zig values so the compiler, runtime, OpenAPI generator, client generator, and tests can share it. This page covers the development tools introduced after v0.0.2; pin `main` until they appear in a tagged release.

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

The resource generator creates a model/repository source file, a factory test, and a timestamped migration. It deliberately does not edit route wiring: import and register the generated resource explicitly. Destroy removes generated source files but retains migrations to avoid accidental data loss.

`api diff` fails when a path or HTTP operation was removed. It currently detects removals; schema-level compatibility is not inferred.

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
