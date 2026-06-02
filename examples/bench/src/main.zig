// Minimal Akamata benchmark server. Three scenarios:
//   GET  /hello       — static text response (framework overhead only)
//   POST /echo        — JSON parse + JSON serialize
//   GET  /db/:id      — SQLite query

const std = @import("std");
const am = @import("akamata");

const State = struct {
    db: am.db.Db,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var db = try am.db.openSqlite(alloc, ":memory:");
    defer db.close();
    try db.execAll(
        \\CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, weight REAL);
        \\INSERT INTO items(id, name, weight) VALUES (1,'alpha',1.5);
        \\INSERT INTO items(id, name, weight) VALUES (2,'beta',2.5);
        \\INSERT INTO items(id, name, weight) VALUES (3,'gamma',3.5);
    );

    var app = am.App(State).init(alloc, .{ .db = db });
    defer app.deinit();

    _ = try app.get("/hello", hello);
    _ = try app.post("/echo", echo);
    _ = try app.get("/db/:id", lookup);

    // BENCH_RUNTIME=reactor switches to the kqueue prototype for A/B tests.
    const rt: am.Runtime = blk: {
        if (am.env.get(alloc, "BENCH_RUNTIME")) |v| {
            defer alloc.free(v);
            if (std.mem.eql(u8, v, "reactor")) break :blk .reactor;
        }
        break :blk .threaded;
    };
    std.log.info("bench runtime: {s}", .{@tagName(rt)});
    try app.serve(.{ .port = 8080, .accept_thread_count = 8, .runtime = rt });
}

fn hello(c: *am.Context(State)) !void {
    try c.text("Hello, Akamata!");
}

fn echo(c: *am.Context(State)) !void {
    const Body = struct { name: []const u8, n: u32 = 0 };
    const body = c.req.json(Body) catch {
        return c.json(.{ .error_kind = "bad_request" }, 400);
    };
    try c.json(.{ .name = body.name, .n = body.n, .echoed = true }, 200);
}

fn lookup(c: *am.Context(State)) !void {
    const id = c.req.paramAs(i64, "id") catch {
        return c.json(.{ .error_kind = "bad_id" }, 400);
    };
    var stmt = try c.state().db.prepare("SELECT id, name, weight FROM items WHERE id = ?");
    defer stmt.deinit();
    try stmt.bindAll(.{id});
    if ((try stmt.step()) != .row) return c.json(.{ .error_kind = "not_found" }, 404);
    const Row = struct { id: i64, name: []const u8, weight: f64 };
    const r = try stmt.readRow(Row);
    try c.json(.{
        .id = r.id,
        .name = try c.arena.dupe(u8, r.name),
        .weight = r.weight,
    }, 200);
}
