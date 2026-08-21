import assert from "node:assert/strict";
import test from "node:test";
import { AkamataRealtimeRoom } from "../deploy/worker/realtime_object.mjs";

function socket(attachment) {
  return {
    attachment, sent: [], closed: null,
    deserializeAttachment() { return this.attachment; },
    send(value) { this.sent.push(value); },
    close(code, reason) { this.closed = { code, reason }; },
  };
}

function room(handler) {
  const sockets = [];
  const ctx = {
    storage: { sql: { exec() { return { toArray: () => [] }; } } },
    blockConcurrencyWhile(fn) { return fn(); },
    getWebSockets() { return sockets; },
  };
  return { value: new AkamataRealtimeRoom(ctx, { AKAMATA_REALTIME_HANDLER: { fetch: handler } }), sockets };
}

test("inbound event is never implicitly broadcast", async () => {
  const { value, sockets } = room(async () => Response.json([]));
  const sender = socket({ connectionId: "a", identity: "device:1", principal: "{}" });
  const peer = socket({ connectionId: "b", identity: "device:2", principal: "{}" });
  sockets.push(sender, peer);
  await value.webSocketMessage(sender, JSON.stringify({ protocol_version: 1, event_type: "signal", payload: { value: 1 } }));
  assert.deepEqual(sender.sent, []);
  assert.deepEqual(peer.sent, []);
});

test("application explicitly controls broadcast except sender", async () => {
  const envelope = { protocol_version: 1, event_type: "accepted", payload: {} };
  const { value, sockets } = room(async () => Response.json([{ kind: "broadcast_except_sender", envelope }]));
  const sender = socket({ connectionId: "a", identity: "device:1", principal: "{}" });
  const peer = socket({ connectionId: "b", identity: "device:1", principal: "{}" });
  sockets.push(sender, peer);
  await value.webSocketMessage(sender, JSON.stringify({ protocol_version: 1, event_type: "signal", payload: {} }));
  assert.equal(sender.sent.length, 0);
  assert.equal(peer.sent.length, 1);
  assert.deepEqual(JSON.parse(peer.sent[0]), envelope);
});

test("malformed, oversized and unsupported messages close predictably", async () => {
  const { value } = room(async () => new Response(null, { status: 426 }));
  const malformed = socket({ connectionId: "a" });
  await value.webSocketMessage(malformed, "{");
  assert.equal(malformed.closed.code, 1007);
  const oversized = socket({ connectionId: "b" });
  await value.webSocketMessage(oversized, "x".repeat(64 * 1024 + 1));
  assert.equal(oversized.closed.code, 1009);
  const version = socket({ connectionId: "c" });
  await value.webSocketMessage(version, JSON.stringify({ protocol_version: 999, event_type: "signal", payload: {} }));
  assert.equal(version.closed.code, 4002);
});
