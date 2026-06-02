// Model definition for the guestbook example. One struct = one table, with
// schema/validation/index declarations sitting next to the field list so
// nothing about the DB shape gets out of sync with the Zig code.

const am = @import("akamata");

pub const Entry = struct {
    id: ?i64 = null,
    name: []const u8,
    message: []const u8,
    created_at: ?i64 = null,

    pub const __schema = .{
        .table = "guestbook",
        .primary_key = "id",
        .indexes = .{
            .{ "created_at", .index },
        },
        .defaults = .{
            .created_at = "unixepoch()",
        },
        .validates = .{
            .name = .{ am.model.rule.required, am.model.rule.max_len(80) },
            .message = .{ am.model.rule.required, am.model.rule.max_len(500) },
        },
    };
};

/// Every TableDef the app cares about. The migrator walks this list to
/// build/alter the database; new models just need to be appended here.
pub const all_models = [_]am.model.TableDef{
    am.model.tableDef(Entry),
};
