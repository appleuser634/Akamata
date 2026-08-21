// Generic Durable Object adapter for Akamata realtime rooms. Domain payloads
// remain opaque versioned envelopes; application schemas live in Zig.
export class AkamataRealtimeRoom {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS akamata_room_state (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS akamata_presence (
          connection_id TEXT PRIMARY KEY,
          identity TEXT,
          metadata TEXT NOT NULL,
          connected_at INTEGER NOT NULL,
          last_seen INTEGER NOT NULL
        )
      `);
    });
  }

  async fetch(request) {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return Response.json(await this.presence());
    }
    // Only the trusted Worker gateway can set these headers. Durable Objects
    // are not directly Internet-addressable, and the gateway never forwards
    // client-supplied X-Akamata-* headers.
    if (request.headers.get("X-Akamata-Authorized") !== "1") {
      return Response.json({ error: "unauthorized" }, { status: 401 });
    }
    const connectionId = request.headers.get("X-Akamata-Connection-Id");
    const identity = request.headers.get("X-Akamata-Logical-Identity");
    const principal = request.headers.get("X-Akamata-Principal");
    const metadata = request.headers.get("X-Akamata-Metadata") ?? "{}";
    if (!connectionId || !identity || !principal) return Response.json({ error: "invalid_authorization_context" }, { status: 500 });
    if (new TextEncoder().encode(metadata).byteLength > 4096) {
      return Response.json({ error: "metadata_too_large" }, { status: 413 });
    }
    try { JSON.parse(metadata); JSON.parse(principal); } catch {
      return Response.json({ error: "invalid_metadata" }, { status: 400 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    const now = Date.now();
    server.serializeAttachment({ connectionId, identity, principal, metadata, connectedAt: now });
    this.ctx.acceptWebSocket(server);
    this.ctx.storage.sql.exec(
      `INSERT INTO akamata_presence(connection_id, identity, metadata, connected_at, last_seen)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(connection_id) DO UPDATE SET identity=excluded.identity,
         metadata=excluded.metadata, connected_at=excluded.connected_at, last_seen=excluded.last_seen`,
      connectionId, identity, metadata, now, now,
    );
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    const attachment = ws.deserializeAttachment();
    if (attachment?.connectionId) {
      this.ctx.storage.sql.exec(
        "UPDATE akamata_presence SET last_seen=? WHERE connection_id=?",
        Date.now(), attachment.connectionId,
      );
    }
    const bytes = typeof message === "string" ? new TextEncoder().encode(message).byteLength : message.byteLength;
    if (bytes > 64 * 1024) {
      ws.close(1009, "message too large");
      return;
    }
    if (typeof message !== "string") {
      ws.close(1003, "text protocol required");
      return;
    }
    let envelope;
    try { envelope = JSON.parse(message); } catch {
      ws.close(1007, "malformed event");
      return;
    }
    if (!envelope || !Number.isInteger(envelope.protocol_version) || typeof envelope.event_type !== "string" || !("payload" in envelope)) {
      ws.close(1007, "malformed event");
      return;
    }
    if (!this.env.AKAMATA_REALTIME_HANDLER || typeof this.env.AKAMATA_REALTIME_HANDLER.fetch !== "function") {
      ws.close(1011, "application handler unavailable");
      return;
    }
    const context = ws.deserializeAttachment();
    const handlerResponse = await this.env.AKAMATA_REALTIME_HANDLER.fetch(new Request("https://akamata.internal/realtime/message", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ context, envelope }),
    }));
    if (!handlerResponse.ok) {
      if (handlerResponse.status === 401 || handlerResponse.status === 403) ws.close(4003, "authorization rejected");
      else if (handlerResponse.status === 426) ws.close(4002, "unsupported protocol version");
      else ws.close(1007, "event rejected");
      return;
    }
    const actions = await handlerResponse.json();
    if (!Array.isArray(actions) || actions.length > 32) {
      ws.close(1011, "invalid handler response");
      return;
    }
    for (const action of actions) await this.applyAction(ws, action);
  }

  async applyAction(sender, action) {
    if (!action || typeof action !== "object") return;
    const encoded = action.envelope == null ? null : JSON.stringify(action.envelope);
    if (encoded && new TextEncoder().encode(encoded).byteLength > 64 * 1024) return;
    if (action.kind === "direct" && typeof action.connection_id === "string" && encoded) {
      await this.send(action.connection_id, encoded);
    } else if (action.kind === "broadcast" && encoded) {
      await this.broadcast(encoded);
    } else if (action.kind === "broadcast_except_sender" && encoded) {
      for (const peer of this.ctx.getWebSockets()) if (peer !== sender) peer.send(encoded);
    } else if (action.kind === "disconnect") {
      const code = Number.isInteger(action.code) ? action.code : 1000;
      sender.close(code, typeof action.reason === "string" ? action.reason.slice(0, 123) : "closed");
    }
  }

  async webSocketClose(ws, code, reason) {
    const attachment = ws.deserializeAttachment();
    if (attachment?.connectionId) {
      this.ctx.storage.sql.exec("DELETE FROM akamata_presence WHERE connection_id=?", attachment.connectionId);
    }
    ws.close(code, reason);
  }

  async webSocketError(ws) {
    const attachment = ws.deserializeAttachment();
    if (attachment?.connectionId) {
      this.ctx.storage.sql.exec("DELETE FROM akamata_presence WHERE connection_id=?", attachment.connectionId);
    }
  }

  async broadcast(envelope) {
    const encoded = typeof envelope === "string" ? envelope : JSON.stringify(envelope);
    let delivered = 0;
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.send(encoded); delivered += 1; } catch { /* stale socket */ }
    }
    return delivered;
  }

  async send(connectionId, envelope) {
    const encoded = typeof envelope === "string" ? envelope : JSON.stringify(envelope);
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.deserializeAttachment()?.connectionId === connectionId) {
        ws.send(encoded);
        return true;
      }
    }
    return false;
  }

  async disconnect(connectionId, code = 1000, reason = "closed") {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.deserializeAttachment()?.connectionId === connectionId) {
        ws.close(code, reason);
        return true;
      }
    }
    return false;
  }

  async presence() {
    const sockets = this.ctx.getWebSockets();
    const members = new Set();
    for (const ws of sockets) {
      const identity = ws.deserializeAttachment()?.identity;
      if (identity) members.add(identity);
    }
    return { connections: sockets.length, members: members.size };
  }

  async putState(key, value) {
    const encoded = JSON.stringify(value);
    this.ctx.storage.sql.exec(
      `INSERT INTO akamata_room_state(key,value,updated_at) VALUES(?,?,?)
       ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
      key, encoded, Date.now(),
    );
  }

  async getState(key) {
    const row = this.ctx.storage.sql.exec(
      "SELECT value FROM akamata_room_state WHERE key=?", key,
    ).toArray()[0];
    return row ? JSON.parse(row.value) : null;
  }
}
