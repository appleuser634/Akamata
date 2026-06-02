# {{NAME}}

A Akamata web app.

## Usage

```bash
# Run locally
zig build run
# or
akamata dev

# Build for Cloudflare Workers (WASM)
akamata build --workers

# Build a static binary for Cloudflare Containers
akamata build --containers

# Deploy
akamata deploy --workers       # requires npx wrangler login
akamata deploy --containers    # requires docker
```
