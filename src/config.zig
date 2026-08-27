//! Typed environment configuration with explicit defaults and secret metadata.
const std = @import("std");
const env = @import("env.zig");

pub const Error = error{ MissingRequired, InvalidValue, UnsupportedType };
pub const Field = struct { name: []const u8, env_name: []const u8, required: bool, secret: bool };

pub fn fields(comptime T: type) [@typeInfo(T).@"struct".fields.len]Field {
    const info = @typeInfo(T).@"struct".fields;
    var out: [info.len]Field = undefined;
    inline for (info, 0..) |field, i| out[i] = .{
        .name = field.name,
        .env_name = comptime envName(T, field.name),
        .required = field.defaultValue() == null and @typeInfo(field.type) != .optional,
        .secret = comptime isSecret(T, field.name),
    };
    return out;
}

pub fn load(comptime T: type, allocator: std.mem.Allocator) !T {
    if (@typeInfo(T) != .@"struct") @compileError("config.load expects a struct");
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const raw = env.get(allocator, comptime envName(T, field.name));
        if (raw) |value| {
            @field(result, field.name) = try parse(field.type, value);
        } else if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else return error.MissingRequired;
    }
    return result;
}

fn parse(comptime T: type, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice and p.child == u8) value else error.UnsupportedType,
        .int => std.fmt.parseInt(T, value, 10) catch error.InvalidValue,
        .bool => if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) true else if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) false else error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(T, value) orelse error.InvalidValue,
        .optional => |optional| try parse(optional.child, value),
        else => error.UnsupportedType,
    };
}

fn envName(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (@hasDecl(T, "__config") and @hasField(@TypeOf(T.__config), "names") and @hasField(@TypeOf(T.__config.names), field_name)) return @field(T.__config.names, field_name);
    return field_name;
}

fn isSecret(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "__config") or !@hasField(@TypeOf(T.__config), "secrets")) return false;
    inline for (T.__config.secrets) |name| if (std.mem.eql(u8, name, field_name)) return true;
    return false;
}

test "typed config metadata" {
    const C = struct {
        port: u16 = 8080,
        token: []const u8,
        debug: bool = false,
        pub const __config = .{ .names = .{ .token = "API_TOKEN" }, .secrets = .{"token"} };
    };
    const schema = fields(C);
    try std.testing.expectEqualStrings("port", schema[0].env_name);
    try std.testing.expect(schema[1].required and schema[1].secret);
}
