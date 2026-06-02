//! Data model for the tasks example.
//!
//! Every model is a plain Zig struct + a `__schema` declaration. The schema
//! tells Akamata how to build the SQL table, which fields to validate on
//! input, and what defaults to use. There is no separate migration DSL —
//! the struct *is* the source of truth, and `am.model.migrate` diffs it
//! against the live database on startup.
//!
//! Keep models small and serializable. If a field doesn't make sense over
//! the wire (a parsed timestamp object, an open file handle, etc.), keep it
//! off the model and compute it inside the handler.

const am = @import("akamata");

/// One row in the `tasks` table. Note the column types:
///   * `?i64` for nullable INTEGER (id is auto-assigned by SQLite, created_at
///     by the DEFAULT clause).
///   * `[]const u8` for TEXT — the Repo handles bind/extract.
///   * `bool` becomes INTEGER 0/1 transparently.
///
/// The struct field names are also the JSON keys when the model is sent in
/// a response: keep them snake_case for consistency with our other APIs.
pub const Task = struct {
    /// `?i64 = null` marks this as auto-assigned: the Repo will skip it
    /// in INSERT and read it back via RETURNING.
    id: ?i64 = null,
    title: []const u8,
    /// Default empty so clients can omit it; the column is still NOT NULL.
    description: []const u8 = "",
    done: bool = false,
    /// Like `id`, populated by SQLite's DEFAULT (unixepoch()).
    created_at: ?i64 = null,

    pub const __schema = .{
        .table = "tasks",
        .primary_key = "id",
        // Composite index on the most common query (active tasks, newest first).
        .indexes = .{
            .{ "created_at", .index },
        },
        // SQL expressions evaluated by the DB on INSERT when the Zig field
        // is null. The framework refuses to bind null for a non-optional
        // field; defaults like this fill the gap server-side.
        .defaults = .{
            .created_at = "unixepoch()",
        },
        // Validation rules. `c.input(Task)` walks these and writes a 422
        // with a structured error list if anything fails — no boilerplate
        // in the handler.
        .validates = .{
            .title = .{ am.model.rule.required, am.model.rule.min_len(1), am.model.rule.max_len(120) },
            .description = .{ am.model.rule.max_len(2000) },
        },
    };
};

/// Migration manifest. Append a new model here when you add one — the
/// migrator walks this list to generate `CREATE TABLE` / `ALTER TABLE`
/// statements at startup.
pub const all_models = [_]am.model.TableDef{
    am.model.tableDef(Task),
};
