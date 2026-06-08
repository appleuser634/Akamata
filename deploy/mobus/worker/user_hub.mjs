// Per-user WebSocket Durable Object. Holds the active socket for one user.

export class UserHub {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.socket = null;
  }

  async fetch(request) {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    server.accept();
    if (this.socket) try { this.socket.close(1000, "replaced"); } catch {}
    this.socket = server;

    server.addEventListener("message", () => { /* clients are listen-only */ });
    const cleanup = () => { if (this.socket === server) this.socket = null; };
    server.addEventListener("close", cleanup);
    server.addEventListener("error", cleanup);

    return new Response(null, { status: 101, webSocket: client });
  }

  /// External push entry point used by message-send handlers.
  async send(payload) {
    if (this.socket) try { this.socket.send(payload); } catch {}
  }
}
