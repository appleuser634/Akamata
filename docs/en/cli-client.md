# CLI API client

The Akamata CLI includes an HTTP client for testing an application without translating every request into curl flags. It uses Akamata's own native HTTP/TLS stack, so CLI usage exercises the same protocol implementation available to applications.

## Full-screen TUI

Run the client without request arguments:

```console
akamata client
# or explicitly
akamata client --tui --base-url=http://127.0.0.1:8080
```

The TUI shows the discovered endpoint list, editable request, and formatted response in one screen. Keys:

- `j` / `k`: select an endpoint
- `Enter`: execute; declared `{path}` parameters are prompted and encoded
- `m`: cycle the HTTP method
- `e`: edit the path or absolute URL
- `h`: edit a request header
- `b`: edit the JSON/raw body
- `u`: change the base URL
- `r`: reload endpoint metadata
- `?`: show help, `q`: quit

Endpoint discovery first runs `zig build run -- akamata-openapi`. Current Akamata scaffolds implement this local inspection protocol after registering their routes, then exit without starting the server. Consequently, every registered route is visible to the TUI without adding `/openapi.json` or another discovery endpoint to the web API. For older applications, the TUI falls back to fetching `/openapi.json`; if neither source is available it opens with a manual request entry.

The runner is invoked only when the current project's `src/main.zig` explicitly contains the inspection marker. Running the TUI from the Akamata framework repository itself therefore opens manual mode instead of accidentally starting the framework's example server.

The application server must still be running when a request is executed. Discovery and serving are deliberately separate so inspection does not mutate the public API surface.

## Direct requests

```console
akamata client /health
akamata client GET /notes --query=page=2 --query=q=zig
akamata client POST /notes --json='{"title":"from CLI","body":"hello"}'
```

The shortest form defaults to GET and `http://127.0.0.1:8080`. Use `--json=@request.json` or `--data=@payload.txt` to read a body from a file. JSON is parsed before a network request and adds `content-type: application/json` unless supplied explicitly.

```console
akamata client GET /me --base-url=https://api.example.com \
  --bearer="$TOKEN" --header=x-request-source:terminal
```

GET, HEAD, POST, PUT, DELETE, PATCH, and OPTIONS are supported. An absolute URL can replace the path.

## Contract-driven calls

When the application exposes its generated OpenAPI document, call an operation by its `operationId`:

```console
akamata api call getNote --param=id=42
akamata api call createNote --json=@note.json
akamata api call getNote --spec=/internal/openapi.json --param=id=42
```

The CLI fetches `/openapi.json`, finds the operation, uses its method/path, percent-encodes `--param` values, and rejects unresolved path parameters. The OpenAPI endpoint must be registered by the application; it is not exposed implicitly.

## Output and automation

JSON responses are pretty-printed by default. `--raw` writes the body unchanged. `--include` prints status and response headers. Add `--fail` in scripts and CI to return non-zero for 4xx/5xx; transport errors, invalid input, size limits, unknown operations, and missing path parameters always fail.

Responses default to a 4 MiB limit. `--max-bytes=N` can raise it to at most 64 MiB.

## Security

- Header values, Bearer tokens, and URLs reject CR/LF injection.
- Query and path parameter values are percent-encoded.
- HTTPS uses Akamata's certificate and hostname verification.
- Response allocation is bounded.
- Command-line secrets may be visible in shell history or process listings. Prefer short-lived environment variables.

Run `akamata help client` for every option. Options use `--name=value`; `-H=name:value` aliases `--header=name:value`.
