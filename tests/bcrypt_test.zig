const std = @import("std");
const am = @import("akamata");

test "bcrypt hash then verify" {
    const alloc = std.testing.allocator;
    const h = try am.auth.bcrypt.hash(alloc, "password123", 4);
    defer alloc.free(h);
    try am.auth.bcrypt.verify("password123", h);
    try std.testing.expectError(am.auth.bcrypt.BcryptError.WrongPassword, am.auth.bcrypt.verify("wrong", h));
}
