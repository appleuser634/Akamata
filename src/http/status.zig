const std = @import("std");

pub const Code = enum(u16) {
    ok = 200,
    created = 201,
    no_content = 204,
    bad_request = 400,
    unauthorized = 401,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    payload_too_large = 413,
    unsupported_media_type = 415,
    unprocessable_entity = 422,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    _,

    pub fn phrase(self: Code) []const u8 {
        return switch (self) {
            .ok => "OK",
            .created => "Created",
            .no_content => "No Content",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .payload_too_large => "Payload Too Large",
            .unsupported_media_type => "Unsupported Media Type",
            .unprocessable_entity => "Unprocessable Entity",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            _ => switch (@intFromEnum(self) / 100) {
                1 => "Informational",
                2 => "OK",
                3 => "Redirect",
                4 => "Client Error",
                5 => "Server Error",
                else => "Unknown",
            },
        };
    }
};

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,

    pub fn parse(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return null;
    }
};
