// Backend-agnostic guestbook handlers, now driven by the `Entry` model.
// The same code runs against SQLite, Turso, and Cloudflare D1 — `am.db.open`
// picks the backend at startup, and the model's Repo handles SQL generation
// + row marshalling.

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const Entry = @import("models.zig").Entry;

const Ctx = am.Context(App);
const Entries = am.model.repo(Entry);

const index_html = @embedFile("index.html");

pub fn index(c: *Ctx) !void {
    const accept = c.req.header("accept") orelse "";
    if (std.mem.indexOf(u8, accept, "text/html") != null) {
        return c.html(index_html);
    }
    try c.json(.{
        .name = "akamata guestbook",
        .backend = @tagName(am.backend),
        .endpoints = .{
            .health = "GET /health",
            .list = "GET /entries",
            .create = "POST /entries  { name, message }",
            .show = "GET /entries/:id",
            .delete = "DELETE /entries/:id",
        },
    }, 200);
}

pub fn health(c: *Ctx) !void {
    var stmt = c.state().db.prepare("SELECT 1") catch {
        return c.json(.{ .status = "db_unavailable" }, 503);
    };
    defer stmt.deinit();
    _ = stmt.step() catch {
        return c.json(.{ .status = "db_unavailable" }, 503);
    };
    try c.json(.{ .status = "ok", .backend = @tagName(am.backend) }, 200);
}

pub fn listEntries(c: *Ctx) !void {
    const entries = try Entries.all(c.db(), c.arena);
    try c.json(.{ .entries = entries }, 200);
}

pub fn createEntry(c: *Ctx) !void {
    // `c.input` parses JSON + runs Entry's __schema.validates; on failure it
    // writes 400/422 and returns null so the handler can early-return.
    const entry = (try c.input(Entry)) orelse return;
    const created = try Entries.create(c.db(), c.arena, entry);
    try c.json(created, 201);
}

pub fn showEntry(c: *Ctx) !void {
    const id = c.req.paramAs(i64, "id") catch return c.badRequest("invalid id");
    const entry = (try Entries.find(c.db(), c.arena, id)) orelse return c.notFound();
    try c.json(entry, 200);
}

pub fn deleteEntry(c: *Ctx) !void {
    const id = c.req.paramAs(i64, "id") catch return c.badRequest("invalid id");
    try Entries.delete(c.db(), id);
    try c.json(.{ .deleted = id }, 200);
}
