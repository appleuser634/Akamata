// Opt-in live Cloudflare smoke test. Never runs from the default test step.
// Required: AKAMATA_LIVE_BASE_URL, AKAMATA_LIVE_SUBJECT,
// AKAMATA_LIVE_LOGIN_SECRET. Resources are isolated under a random key.
import assert from "node:assert/strict";
import crypto from "node:crypto";
import tls from "node:tls";

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

// ESP-IDF-style header-capable WebSocket handshake, implemented with Node TLS
// so the opt-in test does not add a package dependency.
function websocket(url, authorization) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const key = crypto.randomBytes(16).toString("base64");
    const socket = tls.connect({ host: target.hostname, port: Number(target.port || 443), servername: target.hostname });
    let buffered = Buffer.alloc(0);
    const readers = [];
    function drain() {
      while (readers.length && buffered.length >= readers[0].length) {
        const reader = readers.shift();
        const value = buffered.subarray(0, reader.length);
        buffered = buffered.subarray(reader.length);
        reader.resolve(value);
      }
    }
    socket.once("error", reject);
    const read = length => new Promise((readResolve, readReject) => {
      readers.push({ length, resolve: readResolve, reject: readReject }); drain();
    });
    socket.once("secureConnect", () => socket.write([
      `GET ${target.pathname}${target.search} HTTP/1.1`, `Host: ${target.host}`,
      "Connection: Upgrade", "Upgrade: websocket", `Sec-WebSocket-Key: ${key}`,
      "Sec-WebSocket-Version: 13", `Authorization: ${authorization}`, "", "",
    ].join("\r\n")));
    const onHandshake = chunk => {
      buffered = Buffer.concat([buffered, chunk]);
      const end = buffered.indexOf("\r\n\r\n");
      if (end < 0) return;
      socket.off("data", onHandshake);
      const head = buffered.subarray(0, end).toString("utf8");
      buffered = buffered.subarray(end + 4);
      assert.match(head, /^HTTP\/1\.1 101 /);
      const expected = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      const acceptLine = head.split("\r\n").find(line => line.toLowerCase().startsWith("sec-websocket-accept:"));
      assert.equal(acceptLine?.slice(acceptLine.indexOf(":") + 1).trim(), expected);
      socket.on("data", data => { buffered = Buffer.concat([buffered, data]); drain(); });
      resolve({
        send(value) {
          const payload = Buffer.from(value);
          assert.ok(payload.length < 126);
          const mask = crypto.randomBytes(4);
          const frame = Buffer.alloc(2 + 4 + payload.length);
          frame[0] = 0x81; frame[1] = 0x80 | payload.length; mask.copy(frame, 2);
          for (let i = 0; i < payload.length; i++) frame[6 + i] = payload[i] ^ mask[i % 4];
          socket.write(frame);
        },
        async receive() {
          const headBytes = await read(2);
          const opcode = headBytes[0] & 0x0f;
          let length = headBytes[1] & 0x7f;
          if (length === 126) length = (await read(2)).readUInt16BE();
          else if (length === 127) length = Number((await read(8)).readBigUInt64BE());
          const payload = await read(length);
          assert.equal(opcode, 1, "expected text WebSocket frame");
          return payload.toString("utf8");
        },
        close() { socket.end(); },
      });
    };
    socket.on("data", onHandshake);
  });
}

const wsUrl = base.replace(/^http/, "ws") + "/realtime/default";
const first = await websocket(wsUrl, `Bearer ${token}`);
const second = await websocket(wsUrl, `Bearer ${token}`);
first.send(JSON.stringify({ protocol_version: 1, event_type: "signal", payload: { session_id: "live", value: 7 } }));
const relayed = JSON.parse(await Promise.race([
  second.receive(),
  new Promise((_, reject) => setTimeout(() => reject(new Error("WebSocket relay timed out")), 15_000)),
]));
assert.equal(relayed.event_type, "signal");
assert.equal(relayed.payload.value, 7);
first.close(); second.close();

// Prove the Zig control-plane handlers are not reachable on the public URL.
assert.equal((await fetch(`${base}/realtime/message`, { method: "POST" })).status, 404);
assert.equal((await fetch(`${base}/__akamata/realtime/authorize`, { method: "POST" })).status, 404);

console.log(JSON.stringify({ d1: "ok", r2_range: "ok", durable_object_websocket: "ok", internal_routes_public: "blocked" }));
