// Equivalent Node + Fastify bench server (better-sqlite3 for parity with
// Akamata's in-process SQLite).

import Fastify from "fastify";
import Database from "better-sqlite3";

const db = new Database(":memory:");
db.exec(`
  CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, weight REAL);
  INSERT INTO items(id, name, weight) VALUES (1,'alpha',1.5);
  INSERT INTO items(id, name, weight) VALUES (2,'beta',2.5);
  INSERT INTO items(id, name, weight) VALUES (3,'gamma',3.5);
`);
const stmt = db.prepare("SELECT id, name, weight FROM items WHERE id = ?");

const app = Fastify({ logger: false });

app.get("/hello", async () => "Hello, Akamata!");

app.post("/echo", async (req, reply) => {
  const body = req.body;
  if (!body || typeof body.name !== "string") {
    return reply.code(400).send({ error_kind: "bad_request" });
  }
  return { name: body.name, n: body.n ?? 0, echoed: true };
});

app.get("/db/:id", async (req, reply) => {
  const id = Number(req.params.id);
  if (!Number.isFinite(id)) return reply.code(400).send({ error_kind: "bad_id" });
  const row = stmt.get(id);
  if (!row) return reply.code(404).send({ error_kind: "not_found" });
  return row;
});

await app.listen({ port: 8085, host: "0.0.0.0" });
console.log("listening on :8085");
