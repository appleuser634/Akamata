//! Conventional application-error to HTTP mapping. Apps may override via App.onError.
pub const HandlerError = error{ BadRequest, Unauthorized, Forbidden, NotFound, Conflict, UnprocessableEntity, Internal };
pub const HttpError = struct { status: u16, kind: []const u8, message: []const u8 };

pub fn map(err: anyerror) HttpError {
    return switch (err) {
        error.InvalidInput, error.BadRequest, error.InvalidParam => .{ .status = 400, .kind = "bad_request", .message = "bad request" },
        error.Unauthorized, error.InvalidSession, error.ExpiredSession => .{ .status = 401, .kind = "unauthorized", .message = "authentication required" },
        error.Forbidden, error.PermissionDenied => .{ .status = 403, .kind = "forbidden", .message = "forbidden" },
        error.NotFound, error.NoRow => .{ .status = 404, .kind = "not_found", .message = "not found" },
        error.Conflict, error.ConstraintViolation, error.AlreadyExists => .{ .status = 409, .kind = "conflict", .message = "conflict" },
        error.ValidationFailed, error.UnprocessableEntity => .{ .status = 422, .kind = "validation", .message = "validation failed" },
        else => .{ .status = 500, .kind = "internal", .message = "internal server error" },
    };
}

/// Backward-compatible status-only mapper.
pub fn statusForError(err: anyerror) u16 {
    return map(err).status;
}

pub fn defaultHandler(comptime State: type) @import("app.zig").ErrorHandler(State) {
    return struct {
        fn handle(err: anyerror, c: *@import("context.zig").Context(State)) anyerror!void {
            const mapped = map(err);
            try c.json(.{ .error_kind = mapped.kind, .message = mapped.message }, mapped.status);
        }
    }.handle;
}

test "standard application error mapping" {
    try @import("std").testing.expectEqual(@as(u16, 404), map(error.NoRow).status);
    try @import("std").testing.expectEqual(@as(u16, 409), map(error.ConstraintViolation).status);
    try @import("std").testing.expectEqual(@as(u16, 500), map(error.Unexpected).status);
}
