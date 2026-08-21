// Opt-in live Cloudflare smoke test. Never runs from the default test step.
// Required: AKAMATA_LIVE_BASE_URL, AKAMATA_LIVE_SUBJECT,
// AKAMATA_LIVE_LOGIN_SECRET. Resources are isolated under a random key.
import assert from "node:assert/strict";

const base = process.env.AKAMATA_LIVE_BASE_URL?.replace(/\/$/, "");
const subject = process.env.AKAMATA_LIVE_SUBJECT;
const credential = process.env.AKAMATA_LIVE_LOGIN_SECRET;
if (!base || !subject || !credential) {
  console.error("cloudflare-live-test is opt-in; set AKAMATA_LIVE_BASE_URL, AKAMATA_LIVE_SUBJECT and AKAMATA_LIVE_LOGIN_SECRET");
  process.exit(2);
}

const login = await fetch(`${base}/login`, {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ subject, credential }),
});
assert.equal(login.status, 200, "login");
const { access_token: token } = await login.json();
assert.ok(token);
const auth = { authorization: `Bearer ${token}` };

const record = await fetch(`${base}/records`, {
  method: "POST", headers: { ...auth, "content-type": "application/json" },
  body: JSON.stringify({ body: `live-${crypto.randomUUID()}` }),
});
assert.equal(record.status, 201, "D1 write");
const listed = await fetch(`${base}/records`, { headers: auth });
assert.equal(listed.status, 200, "D1 read");
assert.ok((await listed.json()).records.length > 0);

const objectKey = `live/${crypto.randomUUID()}.bin`;
const bytes = new TextEncoder().encode("0123456789");
const uploaded = await fetch(`${base}/objects/${objectKey}`, {
  method: "PUT", headers: { ...auth, "content-type": "application/octet-stream" }, body: bytes,
});
assert.equal(uploaded.status, 201, "R2 put");
const ranged = await fetch(`${base}/objects/${objectKey}`, { headers: { ...auth, range: "bytes=3-6" } });
assert.equal(ranged.status, 206, "R2 range");
assert.equal(await ranged.text(), "3456");
assert.equal(ranged.headers.get("content-range"), "bytes 3-6/10");

// WebSocket authorization requires a custom Authorization header. Browser's
// WebSocket API cannot set it; run the DO parity test with an ESP-IDF client,
// websocat/curl supporting upgrade headers, or the repository's unit contract
// test until a dependency-free Node raw-WebSocket probe is added.
console.log(JSON.stringify({ d1: "ok", r2_range: "ok", websocket: "not_run_requires_header_capable_client" }));
