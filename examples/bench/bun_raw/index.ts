// Equivalent raw Bun.serve bench server (no framework).
// Strips Hono's overhead to isolate the runtime baseline.

import { Database } from "bun:sqlite";

const db = new Database(":memory:");
db.exec(`
  CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, weight REAL);
  INSERT INTO items(id, name, weight) VALUES (1,'alpha',1.5);
  INSERT INTO items(id, name, weight) VALUES (2,'beta',2.5);
  INSERT INTO items(id, name, weight) VALUES (3,'gamma',3.5);
`);
const stmt = db.query("SELECT id, name, weight FROM items WHERE id = ?");

Bun.serve({
  port: 8084,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/hello") {
      return new Response("Hello, Akamata!");
    }
    if (req.method === "POST" && url.pathname === "/echo") {
      try {
        const body = (await req.json()) as { name: string; n?: number };
        return Response.json({ name: body.name, n: body.n ?? 0, echoed: true });
      } catch {
        return Response.json({ error_kind: "bad_request" }, { status: 400 });
      }
    }
    if (req.method === "GET" && url.pathname.startsWith("/db/")) {
      const id = Number(url.pathname.slice("/db/".length));
      if (!Number.isFinite(id)) return Response.json({ error_kind: "bad_id" }, { status: 400 });
      const row = stmt.get(id) as { id: number; name: string; weight: number } | undefined;
      if (!row) return Response.json({ error_kind: "not_found" }, { status: 404 });
      return Response.json(row);
    }
    return new Response("Not Found", { status: 404 });
  },
});
console.log("listening on :8084");
