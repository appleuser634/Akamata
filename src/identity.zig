//! Authentication-neutral principals and credential extraction.
const std = @import("std");

pub const Credential = union(enum) {
    bearer: []const u8,
    api_token: []const u8,
    shared_secret: []const u8,
    custom: struct { header: []const u8, value: []const u8 },
};

pub fn bearer(header: ?[]const u8) !Credential {
    const value = header orelse return error.MissingCredential;
    const prefix = "Bearer ";
    if (value.len <= prefix.len or !std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix))
        return error.InvalidCredential;
    return .{ .bearer = value[prefix.len..] };
}

pub fn fromHeader(req: anytype, comptime name: []const u8) !Credential {
    const value = req.header(name) orelse return error.MissingCredential;
    return .{ .custom = .{ .header = name, .value = value } };
}

pub fn Identity(comptime Principal: type) type {
    return struct {
        principal: Principal,
        authenticated_at_ms: i64,
        credential_kind: enum { bearer, jwt, api_token, shared_secret, custom },
    };
}

test "bearer credential extraction" {
    const c = try bearer("Bearer token-value");
    try std.testing.expectEqualStrings("token-value", c.bearer);
    try std.testing.expectError(error.InvalidCredential, bearer("Basic abc"));
}
