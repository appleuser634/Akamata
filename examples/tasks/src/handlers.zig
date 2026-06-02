//! Request handlers.
//!
//! Each handler takes a `*Ctx` and writes the response via the helpers on
//! it. Errors that bubble up land in the `recover` middleware (which logs
//! them and returns 500); we use that escape hatch for unexpected DB
//! failures and validate user input manually where a graceful 4xx makes
//! more sense.

const std = @import("std");
const am = @import("akamata");
const App = @import("app.zig").App;
const Task = @import("models.zig").Task;

const Ctx = am.Context(App);

/// The Repo type generated for our model. It exposes `find / all / where /
/// create / save / delete`, all of which take the live `Db` handle and an
/// allocator (typically the request arena).
const Tasks = am.model.repo(Task);

// =========================================================================
// Documented endpoints — registered with `app.endpoint(...)` so OpenAPI
// and the TS client generator pick them up automatically.
// =========================================================================

/// Wire-format wrappers that name the request/response shapes. We *could*
/// use the bare `Task` struct in both directions, but giving the input
/// payload its own name (`CreateTaskInput`) makes the generated TS read
/// `client.postTasks(input: CreateTaskInput)` instead of `client.postTasks(input: Task)`,
/// which would also include the auto-assigned `id` and `created_at`.
pub const CreateTaskInput = struct {
    title: []const u8,
    description: []const u8 = "",

    // Input types carry their own validation declarations so `c.input(T)`
    // checks them on the way in. We mirror the model's constraints rather
    // than relying on the Repo to fail at INSERT time — failing at the
    // boundary gives a 422 with field-level errors instead of a 500.
    pub const __schema = .{
        .validates = .{
            .title = .{ am.model.rule.required, am.model.rule.min_len(1), am.model.rule.max_len(120) },
            .description = .{ am.model.rule.max_len(2000) },
        },
    };
};

pub const UpdateTaskInput = struct {
    // All fields nullable — clients send only what they want to change.
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    done: ?bool = null,

    // Validators see optional == null as "field not supplied" and skip
    // the length/format/range rules — so min_len(1) below only fires
    // when the client actually sent `"title": "..."` with an empty
    // string, never when the field is omitted. PATCH semantics work.
    pub const __schema = .{
        .validates = .{
            .title = .{ am.model.rule.min_len(1), am.model.rule.max_len(120) },
            .description = .{ am.model.rule.max_len(2000) },
        },
    };
};

pub const TaskList = struct {
    tasks: []const Task,
};

pub const ListQuery = struct {
    /// Filter: `done=true` returns only completed tasks. Any value
    /// other than the string `"true"` or `"1"` is treated as false.
    done: ?[]const u8 = null,
};

pub fn listTasks(c: *Ctx) !void {
    // `c.db()` is sugar for `c.state().db`. `c.arena` is the per-request
    // arena — anything allocated here lives until the response is flushed.
    const tasks = try Tasks.all(c.db(), c.arena);
    // Apply query filter if present.
    if (c.req.query("done")) |dq| {
        const want_done = std.mem.eql(u8, dq, "true") or std.mem.eql(u8, dq, "1");
        var filtered: std.ArrayList(Task) = .empty;
        for (tasks) |t| if (t.done == want_done) try filtered.append(c.arena, t);
        try c.json(.{ .tasks = filtered.items }, 200);
        return;
    }
    try c.json(.{ .tasks = tasks }, 200);
}

pub fn createTask(c: *Ctx) !void {
    // `c.input(T)` parses JSON + runs the model's `__schema.validates`.
    // On parse failure it writes 400; on validation failure it writes 422
    // with an `{errors:[{field, rule, message}, ...]}` envelope. In both
    // cases it returns `null` so we can early-return.
    const input = (try c.input(CreateTaskInput)) orelse return;

    // Map input → model. We only fill the user-controlled fields; `id`,
    // `created_at`, and `done` stay at their defaults.
    const created = try Tasks.create(c.db(), c.arena, .{
        .title = input.title,
        .description = input.description,
    });

    // Side effects: SSE broadcast + enqueue a "notify" job.
    try emitEvent(c, "task.created", created);
    _ = try c.state().jobs.enqueue("notify", try std.fmt.allocPrint(
        c.arena,
        "{{\"task_id\":{?d}}}",
        .{created.id},
    ), .{});

    try c.json(created, 201);
}

pub fn showTask(c: *Ctx) !void {
    const id = c.req.paramAs(i64, "id") catch return c.badRequest("invalid id");
    const task = (try Tasks.find(c.db(), c.arena, id)) orelse return c.notFound();
    try c.json(task, 200);
}

pub fn updateTask(c: *Ctx) !void {
    const id = c.req.paramAs(i64, "id") catch return c.badRequest("invalid id");
    const input = (try c.input(UpdateTaskInput)) orelse return;

    // Load → mutate → save. The Repo's `save` issues an UPDATE keyed on
    // the primary key, sending only the columns it knows about.
    var task = (try Tasks.find(c.db(), c.arena, id)) orelse return c.notFound();
    if (input.title) |t| task.title = t;
    if (input.description) |d| task.description = d;
    if (input.done) |d| task.done = d;
    try Tasks.save(c.db(), c.arena, &task);

    try emitEvent(c, "task.updated", task);
    try c.json(task, 200);
}

pub fn deleteTask(c: *Ctx) !void {
    const id = c.req.paramAs(i64, "id") catch return c.badRequest("invalid id");
    try Tasks.delete(c.db(), id);
    try emitEvent(c, "task.deleted", .{ .id = id });
    try c.json(.{ .deleted = id }, 200);
}

// =========================================================================
// SSE: live updates
// =========================================================================

/// `GET /events` — open-ended event stream. The client uses `EventSource`
/// to subscribe; we push a `data: {json}` payload every time a task is
/// touched. A periodic heartbeat keeps the connection alive through
/// proxies that drop idle streams.
pub fn streamEvents(c: *Ctx) !void {
    // Pick up the client's Last-Event-ID if it reconnected; we'll skip
    // events with seq <= that.
    var since: u64 = 0;
    if (c.req.header("last-event-id")) |s| {
        since = std.fmt.parseInt(u64, s, 10) catch 0;
    }

    // `am.sse.open` sets text/event-stream + cache-control: no-cache and
    // commits the response headers immediately. The returned Sse hands us
    // a `.send(...) / .heartbeat()` API on top of chunked transfer encoding.
    var sse = try am.sse.open(c);

    const channel = c.state().events;

    // Cap the stream lifetime: the request thread is otherwise pinned
    // forever, and load tests would happily DoS us. 60 s + a JS-side
    // reconnect on close is the standard SSE pattern.
    const deadline_ms = 60_000;
    const poll_ms: u32 = 50;
    var waited_ms: u32 = 0;
    var beat_ms: u32 = 0;

    while (waited_ms < deadline_ms) {
        if (channel.pollAfter(since)) |slot| {
            // Convert the seq to a string id so the client can resume.
            var id_buf: [24]u8 = undefined;
            const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{slot.seq});
            try sse.send(.{ .id = id_str, .event = "task", .data = slot.bytes });
            since = slot.seq;
            beat_ms = 0;
            continue;
        }
        sleepMs(poll_ms);
        waited_ms +|= poll_ms;
        beat_ms +|= poll_ms;
        if (beat_ms >= 15_000) {
            try sse.heartbeat();
            beat_ms = 0;
        }
    }
    // Falling off the loop closes the stream gracefully — the client
    // will get a clean EOF and reopen.
}

// =========================================================================
// Background job handler
// =========================================================================

/// Registered via `queue.handler("notify", ...)` in main.zig. The Worker
/// thread calls this with the JSON payload we enqueued from `createTask`.
///
/// In a real app this is where you'd hit Slack, send a push, write to a
/// log shipping service, etc. We just log it — but the retry/backoff
/// machinery is real: if this fn returns an error, the job is re-scheduled
/// according to `EnqueueOptions.max_attempts` + exponential backoff.
pub fn notifyJob(_: std.mem.Allocator, payload: []const u8) !void {
    std.log.info("[job:notify] {s}", .{payload});
}

// =========================================================================
// Documentation endpoints
// =========================================================================

/// `GET /openapi.json` — serves the generated spec.
///
/// We generate it on every request for simplicity. For a hot path you'd
/// build it once at startup, cache the bytes, and serve from memory; the
/// `etag` middleware would then turn most requests into a 304.
pub fn openapiSpec(c: *Ctx) !void {
    // `c.app()` is the framework's typed back-pointer to the App(State)
    // that's serving this request. We hand it to the OpenAPI generator
    // so it can walk the route table.
    const fw = c.app().?;
    const spec = try am.openapi.generate(@TypeOf(fw.*), fw, c.arena, .{
        .title = "Akamata Tasks API",
        .version = "1.0.0",
        .description = "Example task tracker showing best-practice usage of Akamata.",
    });
    try c.res.header("content-type", "application/json");
    try c.res.writeAll(spec);
}

/// `GET /client.ts` — emits a TypeScript client built from the live route
/// table. The frontend can `curl -O http://localhost:8080/client.ts` and
/// drop it straight into a project; types stay in lock-step with the
/// server because both come from the same source-of-truth structs.
pub fn typescriptClient(c: *Ctx) !void {
    const fw = c.app().?;
    const ts = try am.client_gen.generate(@TypeOf(fw.*), fw, c.arena, .{
        .target = .typescript,
        .base_url = "http://localhost:8080",
    });
    try c.res.header("content-type", "application/typescript");
    try c.res.writeAll(ts);
}

// =========================================================================
// Helpers
// =========================================================================

/// Encode `payload` as JSON and push it into the SSE channel. The handler
/// passes either a `Task` value or an `{ id }` shape; both serialize fine.
fn emitEvent(c: *Ctx, kind: []const u8, payload: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(c.arena);
    try std.json.Stringify.value(.{ .kind = kind, .payload = payload }, .{}, &aw.writer);
    try c.state().events.publish(aw.written());
}

extern "c" fn usleep(usecs: c_uint) c_int;
fn sleepMs(ms: u32) void {
    _ = usleep(@as(c_uint, ms) * 1000);
}
