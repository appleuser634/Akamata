# {{NAME}}

An Akamata web app.

## Usage

```bash
# Run locally
zig build run
# or
akamata dev

# Create and apply a versioned SQLite migration
akamata migrate generate add_widgets
# Edit migrations/<timestamp>_add_widgets.sql, then:
akamata migrate up

# Build for Cloudflare Workers (WASM)
akamata build --workers

# Build a static binary for Cloudflare Containers
akamata build --containers

# Deploy
akamata deploy --workers       # requires npx wrangler login
akamata deploy --containers    # requires docker
```

`build.zig.zon` pins a release-compatible Akamata revision and Zig content
hash. To develop against a local Akamata checkout temporarily, run
`zig build --fork=/path/to/Akamata`.
