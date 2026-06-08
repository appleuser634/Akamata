// Durable Object: 1 ルーム = 1 ChatRoom インスタンス。
// WebSocket 接続を保持し、新着メッセージを参加者全員にブロードキャストする。
// 永続化は DO の SQLite ストレージを利用する (各 DO に独立した SQLite が付く)。

export class ChatRoom {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.sessions = new Set();
    this.state.blockConcurrencyWhile(async () => {
      const db = this.state.storage.sql;
      db.exec(
        "CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, user TEXT NOT NULL, text TEXT NOT NULL, created_at INTEGER NOT NULL)",
      );
    });
  }

  async fetch(request) {
    const upgradeHeader = request.headers.get("Upgrade");
    if (upgradeHeader !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.handleSession(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  handleSession(ws) {
    ws.accept();
    this.sessions.add(ws);

    ws.addEventListener("message", async (evt) => {
      let parsed;
      try {
        parsed = JSON.parse(evt.data);
      } catch {
        parsed = { user: "anon", text: String(evt.data) };
      }
      const user = String(parsed.user ?? "anon");
      const text = String(parsed.text ?? "");
      const created = Math.floor(Date.now() / 1000);

      const db = this.state.storage.sql;
      const { lastRowId } = db.exec(
        "INSERT INTO messages(user, text, created_at) VALUES(?,?,?)",
        user,
        text,
        created,
      );

      const broadcast = JSON.stringify({
        kind: "message",
        id: Number(lastRowId ?? 0),
        user,
        text,
        created_at: created,
      });

      for (const s of this.sessions) {
        try {
          s.send(broadcast);
        } catch {
          this.sessions.delete(s);
        }
      }
    });

    const cleanup = () => this.sessions.delete(ws);
    ws.addEventListener("close", cleanup);
    ws.addEventListener("error", cleanup);
  }
}
