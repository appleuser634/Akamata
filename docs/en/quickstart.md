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

The generated `build.zig.zon` uses `../Akamata` as its local dependency, so create the project next to this checkout:

```bash
cd ..
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
