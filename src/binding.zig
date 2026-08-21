//! Compile-time declarations for portable Workers/native application envs.
const capability = @import("capability.zig");
const std = @import("std");

pub const Kind = enum { d1, r2, durable_object, queue, secret, variable };

fn Marker(comptime kind_value: Kind, comptime declared_name: []const u8) type {
    if (declared_name.len == 0) @compileError("binding name must not be empty");
    return struct {
        pub const binding_kind = kind_value;
        pub const binding_name = declared_name;
        handle: ?*anyopaque = null,
    };
}

pub fn D1(comptime name: []const u8) type {
    return Marker(.d1, name);
}
pub fn R2(comptime name: []const u8) type {
    return Marker(.r2, name);
}
pub fn DurableObject(comptime name: []const u8) type {
    return Marker(.durable_object, name);
}
pub fn Queue(comptime name: []const u8) type {
    return Marker(.queue, name);
}
pub fn Var(comptime name: []const u8) type {
    return Marker(.variable, name);
}

pub fn Secret(comptime name: []const u8) type {
    const Base = Marker(.secret, name);
    return struct {
        pub const binding_kind = Base.binding_kind;
        pub const binding_name = Base.binding_name;
        value: []const u8,

        pub fn reveal(self: @This()) []const u8 {
            return self.value;
        }
        pub fn format(_: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("[REDACTED]");
        }
    };
}

pub fn validate(comptime Env: type, comptime target: capability.Target) void {
    const info = @typeInfo(Env);
    if (info != .@"struct") @compileError("binding environment must be a struct");
    inline for (info.@"struct".fields, 0..) |field, i| {
        if (!@hasDecl(field.type, "binding_kind") or !@hasDecl(field.type, "binding_name"))
            @compileError("environment field " ++ field.name ++ " is not an Akamata binding declaration");
        inline for (info.@"struct".fields[0..i]) |previous| {
            if (comptime @hasDecl(previous.type, "binding_name") and
                std.mem.eql(u8, @field(previous.type, "binding_name"), @field(field.type, "binding_name")))
                @compileError("duplicate binding name: " ++ @field(field.type, "binding_name"));
        }
        const needed: capability.Kind = switch (@field(field.type, "binding_kind")) {
            .d1 => .d1,
            .r2 => .r2,
            .durable_object => .durable_objects,
            .queue => .queues,
            .secret, .variable => continue,
        };
        capability.requireKinds("binding " ++ @field(field.type, "binding_name"), &.{needed}, target);
    }
}

test "worker binding declarations validate" {
    const Env = struct { db: D1("DB"), files: R2("FILES"), events: Queue("EVENTS"), rooms: DurableObject("ROOMS"), token: Secret("TOKEN") };
    comptime validate(Env, .workers);
}

test "secret formatting is always redacted" {
    const S = Secret("TOKEN");
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try aw.writer.print("{f}", .{S{ .value = "never-log-this" }});
    try std.testing.expectEqualStrings("[REDACTED]", aw.written());
}
