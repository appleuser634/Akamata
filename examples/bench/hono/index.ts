// Equivalent Hono on Bun bench server.
// Run with: bun install && bun run index.ts
import { Hono } from "hono";
import { Database } from "bun:sqlite";

const db = new Database(":memory:");
db.exec(`
  CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, weight REAL);
  INSERT INTO items(id, name, weight) VALUES (1,'alpha',1.5);
  INSERT INTO items(id, name, weight) VALUES (2,'beta',2.5);
  INSERT INTO items(id, name, weight) VALUES (3,'gamma',3.5);
`);
const stmt = db.query("SELECT id, name, weight FROM items WHERE id = ?");

const app = new Hono();

app.get("/hello", (c) => c.text("Hello, Akamata!"));

app.post("/echo", async (c) => {
  try {
    const body = await c.req.json<{ name: string; n?: number }>();
    return c.json({ name: body.name, n: body.n ?? 0, echoed: true });
  } catch {
    return c.json({ error_kind: "bad_request" }, 400);
  }
});

app.get("/db/:id", (c) => {
  const id = Number(c.req.param("id"));
  if (!Number.isFinite(id)) return c.json({ error_kind: "bad_id" }, 400);
  const row = stmt.get(id) as { id: number; name: string; weight: number } | undefined;
  if (!row) return c.json({ error_kind: "not_found" }, 404);
  return c.json(row);
});

export default { port: 8082, fetch: app.fetch };
