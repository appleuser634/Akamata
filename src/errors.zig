pub const HandlerError = error{
    BadRequest,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    UnprocessableEntity,
    Internal,
};

pub fn statusForError(e: anyerror) u16 {
    return switch (e) {
        error.BadRequest => 400,
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.NotFound => 404,
        error.Conflict => 409,
        error.UnprocessableEntity => 422,
        else => 500,
    };
}
