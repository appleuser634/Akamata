# mobus_server_zig porting plan (compatible with both Workers + Containers)

> Historical porting plan. Its phase status and descriptions of bridge stubs are superseded by the current `examples/mobus/` and `deploy/mobus/` implementations. Use the [deployment guide](mobus-deployment.md) for current instructions.

Phased plan for fully porting `../mobus_server_zig` to Akamata and hosting it in both Cloudflare Workers and Cloudflare Containers.

## Porting scope

Of the functions that mobus_server_zig currently has, Akamata supports:

| Features | Workers | Containers | Notes |
|---|---|---|---|
| HTTP/1.1 + 26 REST endpoints | ✅ | ✅ | Routing is rewritten to Akamata's `Router(App).build` |
| WebSocket hub (per user_id) | ✅ DO | ✅ in-memory | Workers uses Durable Object `UserHub` for 1 user and 1 instance |
| SQLite (6 tables + E2EE prekey) | ✅ D1 | ✅ File | Ephemeral disk is not possible with Workers, so D1 is the only choice |
| JWT (HS256) authentication | ✅ | ✅ | Add `auth/jwt.zig` to Akamata |
| bcrypt password hash | ✅ | ✅ | Add `auth/bcrypt.zig` to Akamata (pure Zig) |
| Environment variables / .env loader | ⚠ Workers `vars`/`secrets` | ✅ .env | `env.zig` added to Akamata. In Workers, inject `env.X` to WASM as a props on the JS side |
| OpenWeatherMap REST calls | ✅ Via JS `fetch` | ✅ Zig HTTPS client | Added `http_client.zig` to Akamata. When `backend == .workers`, call JS `fetch()` via extern fn |
| FCM HTTP v1 + Service Account signature | ✅ JS via `fetch` | ✅ Zig HTTPS + RS256 | RS256 signature uses `std.crypto.sign.rsa` (available in 0.16) |
| MQTT Publisher | ⚠ HTTP/WebSocket bridge | ✅ Pure Zig MQTT QoS0 | TCP cannot be accessed directly with Workers. Switch to **MQTT over WebSocket** like HiveMQ Cloud or jump to an alternative REST with `fetch()` |
| Data load at startup + Mutex protection cache | ✅ DO constructor | ✅ in-memory | Localized in DO for Workers, once at process startup for Containers |

**Candidates for exclusion from portability** (confirm with user):
- CLI client / dashboard binary (postponed as server porting is the main purpose)

## Architecture adjustment

The original design of mobus was "single binary + libmosquitto + libssl + local SQLite", but we abstract this into three levels so that the same handler code works in both environments:

```
Handler (am.Context(App)) ──┬─── am.db.Db (SQLite | D1)
                          ├─── am.http_client.Client (Zig TLS | fetch bridge)
                          ├─── am.push.Sender (FCM)
                          ├─── am.mq.Publisher (MQTT direct | webhook bridge)
                          └─── am.env.* (process.Environ | bound vars)
```

- Each abstraction is **vtable** (same pattern as `Db`), implementation replaced in `backend`
- When in Workers mode, external I/O is basically **`await fetch()` on the JS side → writes the result to WASM memory**
- When in Containers mode, external I/O is completed with **synchronous Zig implementation**

## Phase planning

### Phase A: Common Utility Extensions (Framework)

a1. **`src/env.zig`** — `getEnv(name) ?[]const u8` / `requireEnv(name) ![]const u8` / `loadDotEnv(path)`. Via `std.process.Environ` for Containers and `extern fn akamata_env_get(name_ptr, name_len, out_ptr_max)` for Workers
a2. **`src/auth/jwt.zig`** — HS256 sign/verify (`std.crypto.auth.hmac.HmacSha256`), JSON header/payload encode
a3. **`src/auth/bcrypt.zig`** — Pure Zig implementation of Blowfish setup + EksBlowfishSetup (based on mbedTLS-like reference implementation. `std.crypto.pwhash` doesn't have bcrypt, so make your own)
a4. **`src/crypto/rs256.zig`** — RS256 signature (`std.crypto.sign.rsa`). For FCM
a5. **`src/http_client.zig`** — Abstract `Client` type (vtable: native is Zig TLS, workers is extern fn → JS `fetch`)
a6. **`src/push.zig`** — Map `Sender.send(notification)` to FCM HTTP v1
a7. **`src/mq.zig`** — Map `Publisher.publish(topic, payload)` to MQTT (native: TCP directly, workers: via webhook)
a8. **`src/runtime/workers.zig` extension** — Added extern fn declaration above
a9. **`deploy/worker/index.mjs` extension** — Implement `akamata_env`, `akamata_fetch`, `akamata_mq_publish` on the JS side, `await fetch()` → synchronous step method (same 2-pass coroutine as D1)
a10. **Making the D1 bridge full-scale** — Switch the current “pre-fetched array” stub to “wait with Atomics.wait or 2-pass until Promise resolve” design

### Phase B: mobus application layer porting (`examples/mobus/`)

b1. **Create directory** — `examples/mobus/src/{main.zig, worker.zig, app.zig, routes.zig, handlers/, schema.sql, migrations/}`
b2. **Schema** — merge mobus migrations 5 files into `examples/mobus/src/schema.sql`
b3. **JWT middleware** — Verify `Authorization: Bearer <jwt>`, inject into `Ctx.user_id`
b4. **Authentication handler** — `/api/auth/{register,login,login-id-available}` (bcrypt + JWT issue)
b5. **Friend handler** — `/api/friends/*` 5 endpoints
b6. **Message handler** — `/api/messages/*` + `/api/friends/:id/messages/*`
b7. **Real-time call handler** — `/api/rtchat/*` 5 endpoints + WS signaling
b8. **Device CRUD** — `/api/devices*`
b9. **Weather** — `/api/weather/forecast` (http_client + OpenWeatherMap key)
b10. **Communication** — `/api/ping`, `/api/public/ping`, `/api/user/refresh-friend-code`
b11. **WebSocket Hub** — native: `UserHub`, Workers: Durable Object `UserHub`
b12. **MQTT notification / FCM Push** — trigger when message is received

### Phase C: Cloudflare Integration (`deploy/mobus/`)

c1. **`deploy/mobus/wrangler.toml`** — D1 (`MOBUS_DB`), Durable Object (`UserHub`), `secrets` (`JWT_SECRET`, `MQTT_*`, `FCM_*`, `WEATHER_KEY`), Containers binding
c2. **`deploy/mobus/worker/`** — `index.mjs` (JS glue), `user_hub.mjs` (DO), `d1_schema.sql`
c3. **`deploy/mobus/Dockerfile`** — Static binary for Containers + `linkSystemLibrary("ssl", "crypto")` (MQTT is a pure Zig implementation and libmosquitto dependency removed)

### Phase D: Test documentation

d1. **Add tests** — JWT/bcrypt unit tests, env loader, http_client mock
d2. **`docs/en/mobus-deployment.md`** — D1 migration procedure, `wrangler secret put` list, Containers startup procedure
d3. **CI matrix extension** — `examples/mobus` is also built on both targets

## Expected man-hours

| Phase | Contents | Man-hours (assuming one person) |
|---|---|---|
| A | Framework extension (env/jwt/bcrypt/http_client/push/mq + WASM bridge) | 4-6 days |
| B | mobus application layer, WebSocket, and notifications | 5-7 days |
| C | Cloudflare integration (wrangler.toml + Worker JS + Dockerfile) | 2-3 days |
| D | Test + Documentation + CI | 2 days |
| **Total** | | **13-18 days** |

## Main risks

1. **Reentrant design for D1 synchronization** — Currently, the D1 bridge is a “stub that returns pre-fetched data” and the implementation is incomplete. To make it work, WASM ↔ JS bidirectional reentrancy is required (Phase A10 is key)
2. **Pure Zig implementation of bcrypt** — Requires verification of correctness of reference implementation. Compatibility test vector required (create `docs/en/known-answer-tests.md`)
3. **MQTT Replacement** — If you continue to use MQTT broker in production operations, you will need a connection code to an **MQTT over WebSocket** broker (such as HiveMQ Cloud) for the Workers environment. Or the application's decision to give up on MQTT and replace it with HTTP webhook + Durable Object.
4. **bcrypt RSA key parsing** (for FCM) — Check if the PEM part of Service Account JSON can be parsed with `std.crypto.Certificate.rsa` of 0.16.
5. **TLS Client** — `std.crypto.tls.Client` is being rewritten in 0.16. HTTP/1.1 + TLS wrapper required on Akamata side

## Recommended implementation order

1. Phase A1 (env) + A2 (jwt) — At least run only authentication
2. Complete Phase B2 (schema) + B3-B4 (auth) with **Containers first**
3. Complete Phase A5 (http_client) + A6 (push) with Containers
4. Complete the rest of Phase B (friends, messages, ...) with Containers
5. Phase A8-A10 (Workers Bridge) — Run the code written in B without changing it for Workers
6. Finish with Phase C, D

With this method, you can check the operation at each step and concentrate on solving the difficult part of Workers support (D1 reentrant) at the end.

## Final policy (agreed on 2026-05-22)

1. **MQTT**: Implements pure Zig MQTT QoS0 only in Containers. Workers returns 501 for MQTT related endpoints
2. **Password hash**: Implement bcrypt with pure Zig and maintain compatibility with mobus existing data
3. **CLI client / dashboard**: This time only the server is ported**. CLI/dashboard for later
4. **Existing `mobus_data.db`**: Discard the data and bring only the schema to Akamata (generate D1 migration SQL)
5. **E2EE prekey**: Ported mobus tables (`envelopes`, `device_one_time_prekeys`) and endpoints as is. Guaranteed compatibility with Expo clients
