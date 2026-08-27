const am = @import("akamata");

test "unsupported bind arrays fail explicitly" {
    const words = [_]u16{ 1, 2 };
    _ = am.db.Value.fromAny(words);
}
