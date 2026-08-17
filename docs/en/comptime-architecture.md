# Compile-time architecture

Akamata treats the Zig compiler as part of the framework. Runtime APIs remain
the flexible default; static APIs move validation and selected dispatch work
to compilation when an application can describe its graph up front.

## One core, two registration models

The runtime model is unchanged:

```zig
var app = am.App(State).init(gpa, state);
_ = try app.get("/users/:id", getUser);
```

The additive static model reuses `contract.Endpoint`, `Context`, OpenAPI route
views, the TypeScript generator, and the same dispatch core:

```zig
const GetUser = am.contract.Endpoint(
    .GET, "/users/:id", getUser, .{ .operation_id = "getUser" },
);
const Api = am.Routes(.{GetUser});

comptime {
    Api.validate();
    Api.validateTarget(.workers);
}

_ = try app.mountStatic(Api);
```

`mountStatic` must be the final route registration. Graphs of at most 32 routes
use an allocation-free, unrolled matcher. Larger graphs retain compile-time
validation but select the compact runtime matcher. Fully specializing 100–500
routes increased code size and hurt the instruction cache in measurements; the
threshold is therefore a deliberate zero-cost/size boundary, not a limitation
of validation.

## Validation performed by the compiler

The route graph rejects invalid leading paths, duplicate and structurally
ambiguous method/path pairs, unnamed or non-terminal wildcards, duplicate path
parameters, and duplicate operation IDs. `BoundForPath` additionally checks
that every `Path` input exists, input source/name pairs are unique, only one
JSON body exists, and every field uses a supported input marker.

`TypedEndpoint` reflects `(Context, Inputs) ErrorSet!Response`. It:

- extracts `Path`, `Query`, `Header`, `Cookie`, and `Json` inputs;
- infers JSON request and response schemas;
- requires an exhaustive finite error-set mapping;
- uses that mapping for HTTP responses and OpenAPI responses;
- feeds the existing OpenAPI and TypeScript-client metadata path.

```zig
const Inputs = struct {
    id: am.contract.Path(u64, "id"),
    limit: am.contract.Query(?u32, "limit"),
};

fn find(c: *am.Context(State), input: Inputs)
    error{NotFound, DatabaseUnavailable}!User
{ ... }

const Find = am.contract.TypedEndpoint(
    State, .GET, "/users/:id", find,
    .{
        .NotFound = am.Status.not_found,
        .DatabaseUnavailable = am.Status.service_unavailable,
    },
    .{ .operation_id = "findUser" },
);
```

Descriptions, tags, and operation IDs remain explicit because Zig types cannot
truthfully infer prose or public naming.

## Capabilities and DI

`capability.Kind` describes filesystem, threads, sockets, SQLite, D1, Durable
Objects, outbound HTTP, WebSocket, persistent disk, and cryptographic random.
`capability.Requires(Endpoint, requirements)` decorates the existing endpoint;
`validateTarget` rejects unavailable facilities before a Workers/native/
container artifact is built.

`di.Graph` extends provider validation with cycle detection and a dependency-
first topological order. Its registry remains zero-allocation and caller-owned;
the framework does not become a runtime service locator.

## Middleware, DB, SQL, and ownership

`static_middleware.Chain` composes stateless middleware types into direct calls
without a runtime slice or `Next.index`. Stateful and dynamic middleware stays
on `App.use`.

`db.Static(Backend)` is a direct-dispatch adapter for concrete backends, while
portable `Db`/`Stmt` VTables remain unchanged. `db.Query(sql, Args, Row)` checks
placeholder count, tuple shape, and supported nullable/scalar Zig types without
claiming knowledge of a deployed schema. `Stmt.readRow` now distinguishes
nullable fields and rejects SQL NULL for non-null fields.

Request slices are borrowed unless documented otherwise. `requestAllocator()`
names the request-lifetime arena explicitly, and `ownRequestBytes()` makes the
ownership transition visible. Application state and `App.own` keep their
existing application lifetime.

## Trade-offs

| Model | Flexibility | Compile-time safety | Dispatch | Binary/build cost |
|---|---|---|---|---|
| Runtime | routes/plugins may be selected dynamically | registration-time errors | hash static path + parsed dynamic scan | smallest source instantiation |
| Static, ≤32 routes | fixed graph | strongest | unrolled matcher | more generated code/build work |
| Static, >32 routes | fixed graph | strongest | shared compact matcher | bounded specialization |

Static routing is not promised to beat the mature runtime hash fast path for a
single static route. Its primary guarantee is invalid-state elimination; the
selective threshold prevents that safety from causing unbounded code growth.

## Current boundary

The compiler validates SQL/Zig shape, not database schemas. Built-in database
openers still return portable `Db`; concrete built-in static handles and a
schema-aware build step are future work. Middleware flattening currently covers
stateless static middleware; runtime-configured middleware remains dynamic.
