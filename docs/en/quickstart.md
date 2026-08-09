# Quick Start

Create and run Akamata's generated Note API in about five minutes.

## Requirements

- Zig 0.16.x
- Git and a POSIX shell
- Node.js and Wrangler only for Cloudflare Workers
- Docker only for Cloudflare Containers

The native build includes the SQLite amalgamation and links libc. OpenSSL is optional and is only required when enabling FCM RS256 support with `-Dopenssl=true`.

## 1. Install the CLI

Clone Akamata and run the installer:

```bash
git clone https://github.com/appleuser634/Akamata.git
cd Akamata
./scripts/install.sh
akamata help
```

The installer builds the CLI and installs it to `$HOME/.local/bin` by default. Ensure that directory is on `PATH`. To work directly from a source checkout instead:

```bash
zig build cli
./zig-out/bin/akamata help
```

## 2. Generate a project

The generated `build.zig.zon` uses a release-compatible, revision-pinned GitHub archive with a Zig content hash, so the project can be created independently of the Akamata checkout. The first v0.0.1 scaffold uses an immutable release-preparation revision; subsequent releases update this pin to the previous stable release to avoid a self-referential archive:

```bash
cd ~/projects
akamata init myapp --target=both
cd myapp
```

`--target` accepts `native`, `workers`, `containers`, or `both`; its default is `native`. `both` generates:

```text
myapp/
├── .gitignore
├── README.md
├── build.zig
├── build.zig.zon
├── migrations/
│   └── .gitkeep
├── src/
│   ├── main.zig
│   └── worker.zig
└── deploy/
    ├── Dockerfile
    ├── wrangler.toml
    └── worker/
        └── index.mjs
```

The scaffold is a working SQLite-backed Note API, not a Hello World placeholder. It defines a validated `Note` model and these routes:

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/` | Describe the generated API |
| `GET` | `/health` | Health check |
| `GET` | `/notes` | List notes |
| `POST` | `/notes` | Create a note from `{ "title", "body" }` |
| `GET` | `/notes/:id` | Fetch one note |
| `DELETE` | `/notes/:id` | Delete one note |

The native entry point computes and applies the model schema diff at startup. The Workers entry point uses `migrate.Once` so initialization runs once per isolate.

The first build downloads the pinned Akamata source. To test a local Akamata checkout without editing `build.zig.zon`, use Zig 0.16's package override:

```bash
zig build --fork=/path/to/Akamata
```

## 3. Run the native server

```bash
zig build run
```

The server reports that it is listening on port 8080. From another terminal:

```bash
curl -sS http://127.0.0.1:8080/
curl -sS http://127.0.0.1:8080/health
curl -sS http://127.0.0.1:8080/notes
curl -sS -X POST -H 'content-type: application/json' \
  -d '{"title":"hello","body":"first note"}' \
  http://127.0.0.1:8080/notes
```

The local database is `myapp.db` unless `DATABASE_URL` overrides it.

Versioned migrations are also available. A fresh scaffold contains an empty `migrations/` directory, and applying it is a successful no-op:

```bash
akamata migrate generate add_widgets
# Edit the generated SQL file.
akamata migrate up
```

Applied versions are recorded in `schema_migrations`; running `migrate up` again skips them. Use `--dir=PATH` for another directory or `--target=VERSION` to stop at a version.

## 4. Build other targets

Workers:

```bash
zig build -Dbackend=workers -Doptimize=ReleaseSmall
cd deploy
npx wrangler dev --local
```

Before using the generated app with D1, create a D1 database and enable/update the commented `[[d1_databases]]` binding in `deploy/wrangler.toml`. The binding name must remain `DB` unless you also change the application.

Containers:

```bash
akamata deploy --containers
docker run --rm -p 8080:8080 akamata-app
```

For a Workers deployment after configuring Wrangler:

```bash
npx wrangler login
akamata deploy --workers
```

## Next steps

- [Tutorial](tutorial.md): build a complete application step by step
- [Handbook](handbook.md): a compact tour of models, repositories, migrations, and deployment
- [Handler API reference](handler-api.md): current public APIs and lifetimes
- [Database backends](db-backends.md): SQLite, D1, and Turso
- [WebSocket guide](websocket.md)
- [Documentation home](README.md)
