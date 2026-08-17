# Security

Akamata rejects ambiguous HTTP/1 framing at the framework boundary. HTTP/1.1 requests require exactly one valid `Host`; whitespace before a header colon, obs-fold, duplicate `Host` or `Content-Length`, CL/TE combinations, unsupported transfer codings, malformed chunks, and oversized inputs are rejected.

## Native server limits

The threaded native runtime separates acceptance from bounded connection workers. Defaults are: 10 s header deadline, 30 s body deadline, 5 s keep-alive idle deadline, 60 s total request deadline, 100 requests per connection, 1,024 concurrent connections, 64 KiB headers, and 4 MiB bodies. Configure these through `ServeOptions`. Put a maintained TLS reverse proxy in front for public deployments, but do not rely on a proxy to repair malformed framing.

`ServeOptions.trust_proxy_headers` defaults to `false`, so `c.req.ip()` ignores
`X-Forwarded-For`, `CF-Connecting-IP`, and `X-Real-IP`. The threaded native
server reports the socket peer; targets without peer metadata may return
`null`. Enable forwarding headers only when every direct connection is from a
proxy you control. The in-process rate limiter is bounded but local to one
process/isolate; multi-node enforcement needs a shared limiter.

`secureHeaders` is applied before handlers so streaming responses receive the policy. Its HSTS default is for HTTPS production; disable `strict_transport_security` on plain-HTTP development hosts to avoid teaching a browser an unusable HTTPS policy.

## Authentication and cookies

`am.mw.jwt` accepts HS256 only, requires `exp` by default, and validates `exp` and `nbf`. Use a random secret with at least 32 bytes of entropy. `now_fn` exists for deterministic tests; `leeway_seconds` should remain small.

Sessions require a stable secret of at least 32 bytes. Their signed cookie includes an expiry that is checked even with a persistent Store. Session and CSRF cookies are `Secure` by default; explicitly disable this only for plain-HTTP local development. Session cookies are also `HttpOnly` and `SameSite=Lax`. Rotate the SID after login and privilege changes with `session.rotate(c)`.

Apply CSRF protection to cookie-authenticated state-changing routes. CORS does not replace CSRF protection. Akamata rejects `origin="*"` with `credentials=true`; configure an exact trusted origin. Do not reflect arbitrary request origins.

## WebSocket and uploads

WebSocket handshakes require version 13 and a valid 16-byte nonce. Client frames must be masked; reserved opcodes/bits, fragmented or oversized control frames, invalid fragmentation, invalid close payloads, invalid UTF-8 text, and messages over the configured limit are rejected. `UpgradeOptions` defaults to a 60-second read timeout and supports an exact `allowed_origins` allowlist.

Multipart and URL-encoded parsing has bounded body, part/field, header, boundary, and count limits. Treat uploaded filenames as display metadata, never as a filesystem path.

## Migration notes

- JWT middleware now rejects expired tokens and tokens without `exp` by default. Set `require_exp=false` only for a deliberate legacy migration.
- Session and CSRF cookies now default to `Secure`; local HTTP setups must opt out.
- Existing two-component session cookies are invalidated because the signed format now includes expiry.
- Duplicate Content-Length and other formerly tolerated HTTP ambiguity is rejected.

See the repository [security policy](../../SECURITY.md) for vulnerability reporting.
