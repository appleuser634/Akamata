# examples/guestbook

A minimal REST API (`/entries` CRUD) that demonstrates Akamata's **URL-driven
DB backend switch**. The exact same handler code runs against:

- **SQLite** (`file:./guestbook.db`) — native, VPS, Cloudflare Containers
- **Turso / libsql** (`libsql://<db>.turso.io?authToken=…`) — native or Workers
- **Cloudflare D1** (`d1:DB`) — Workers only

Switching backends is a one-line change to the `DATABASE_URL` env var. No code
changes, no recompile-with-different-flags.

## Endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/` | **Browser** (`Accept: text/html`) → HTML UI<br>**curl/fetch** (`Accept: application/json` or `*/*`) → endpoint map + active backend |
| GET | `/health` | `SELECT 1` round-trip — also returns `backend: "native" \| "workers"` |
| GET | `/entries` | last 100 entries, newest first |
| POST | `/entries` | body: `{ "name": "...", "message": "..." }` |
| GET | `/entries/:id` | one entry |
| DELETE | `/entries/:id` | delete one entry |

The HTML UI is `examples/guestbook/src/index.html` embedded with `@embedFile`
so it ships inside the binary / wasm — no static-asset hosting needed.
After `wrangler deploy`, open the worker URL in a browser:
`https://guestbook.<your-subdomain>.workers.dev/` shows a form + entry list,
hitting the same `/entries` JSON endpoints via `fetch()`.

## Run locally with SQLite

```bash
zig build -Dexample=guestbook -Doptimize=ReleaseFast
DATABASE_URL=file:./guestbook.db PORT=8080 ./zig-out/bin/guestbook
```

Schema is bootstrapped automatically for `file:` URLs.

```bash
curl -s -X POST -H 'content-type: application/json' \
  -d '{"name":"musashi","message":"hi"}' \
  http://127.0.0.1:8080/entries
curl -s http://127.0.0.1:8080/entries
```

## Run locally with Turso

```bash
turso db create akamata-guestbook
turso db shell akamata-guestbook < examples/guestbook/src/schema.sql
turso db tokens create akamata-guestbook   # bearer JWT

DATABASE_URL='libsql://akamata-guestbook-<org>.turso.io?authToken=eyJab.c' \
PORT=8080 ./zig-out/bin/guestbook
```

Same binary, same `curl` calls. The handler code does not know it changed.

## Deploy to Cloudflare Workers + D1

The schema is derived at build time from `src/models.zig`. Dump it once,
then deploy:

```bash
# from the project root
zig build -Dexample=guestbook -Doptimize=ReleaseFast
./zig-out/bin/guestbook --print-schema > /tmp/guestbook.sql

akamata deploy --workers \
  --config=deploy/guestbook/wrangler.toml \
  --migrate=/tmp/guestbook.sql
```

On the first run `akamata`:

1. Sees `database_id = "00000000-..."` in `wrangler.toml`
2. Runs `wrangler d1 create guestbook`, parses the new UUID, writes it back
3. Runs `wrangler d1 execute guestbook --remote --file=/tmp/guestbook.sql`
4. `zig build -Dbackend=workers -Doptimize=ReleaseSmall`
5. `wrangler deploy --config=...`

Subsequent runs skip step (1)–(2). To redeploy without re-running the
migration, drop `--migrate`.

## Deploy to Cloudflare Workers + Turso

Edit `deploy/guestbook/wrangler.toml`:

```toml
[vars]
DATABASE_URL = "libsql://akamata-guestbook-<org>.turso.io?authToken=eyJab.c"

# Comment out [[d1_databases]] — not needed when DATABASE_URL is libsql://
```

`wrangler deploy`. Same wasm, same handlers. The JSPI bridge transparently
routes outbound libsql calls through `fetch()`.

## File layout

```
examples/guestbook/
├── README.md
└── src/
    ├── app.zig         # State: { db: am.db.Db }
    ├── handlers.zig    # CRUD handlers (backend-agnostic)
    ├── setup.zig       # Shared route + state wiring (used by main and worker)
    ├── schema.sql      # guestbook table + index
    ├── main.zig        # native entry: reads DATABASE_URL, am.App.serve
    └── worker.zig      # Workers entry: same setup.zig, wasm export

deploy/guestbook/
├── wrangler.toml       # vars.DATABASE_URL — flip d1:DB <-> libsql:// here
└── worker/
    ├── index.mjs       # JSPI host: D1 + outbound fetch bridges
    └── d1_schema.sql   # applied once with `wrangler d1 execute`
```

## How the switch works under the hood

`src/setup.zig`:

```zig
const url = am.env.get(alloc, "DATABASE_URL") orelse default;
var database = try am.db.open(alloc, url);
```

`am.db.open` inspects the URL prefix:

| prefix | backend | available on |
|---|---|---|
| `file:`     | SQLite (sqlite3.c linked in) | native |
| `libsql://` / `https://` / `http://` | Turso/libsql via Hrana v3 HTTP | both |
| `d1:`       | Cloudflare D1 binding via JSPI | Workers |

Workers asynchronicity is bridged by JSPI: `new WebAssembly.Suspending(fn)`
wraps every async import (D1 and `fetch`), and `WebAssembly.promising(handle_fetch)`
wraps the wasm entry. The Zig side just calls them as ordinary synchronous
functions.

See `docs/db-backends.md` for the full picture.
