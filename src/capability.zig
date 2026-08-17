//! Package capability declarations checked against deployment targets.
pub const Target = enum { native, workers, containers };

/// Fine-grained facilities that framework components may require. This list
/// describes semantics, not implementation modules, so routes, middleware,
/// DI providers, and database backends can share it.
pub const Kind = enum {
    filesystem,
    threads,
    sockets,
    sqlite,
    d1,
    durable_objects,
    outbound_http,
    websocket,
    persistent_disk,
    crypto_random,
};

pub const Set = struct {
    native: bool = true,
    workers: bool = true,
    containers: bool = true,
    needs_filesystem: bool = false,
    needs_threads: bool = false,
    needs_network: bool = false,

    pub fn supports(self: Set, target: Target) bool {
        return switch (target) {
            .native => self.native,
            .workers => self.workers,
            .containers => self.containers,
        };
    }
};

pub fn require(comptime package_name: []const u8, comptime capabilities: Set, comptime target: Target) void {
    if (!capabilities.supports(target)) @compileError(package_name ++ " does not support target " ++ @tagName(target));
    if (target == .workers and (capabilities.needs_filesystem or capabilities.needs_threads))
        @compileError(package_name ++ " requires capabilities unavailable on Workers");
}

pub fn available(comptime target: Target, comptime kind: Kind) bool {
    return switch (target) {
        .native => switch (kind) {
            .d1, .durable_objects => false,
            else => true,
        },
        .workers => switch (kind) {
            .filesystem, .threads, .sockets, .sqlite, .persistent_disk => false,
            else => true,
        },
        .containers => switch (kind) {
            .d1, .durable_objects => false,
            else => true,
        },
    };
}

/// Reject target-incompatible requirements with a diagnostic that identifies
/// the declaring route/module and the unavailable facility.
pub fn requireKinds(comptime subject: []const u8, comptime required: []const Kind, comptime target: Target) void {
    inline for (required) |kind| if (!available(target, kind)) {
        @compileError(subject ++ " requires " ++ @tagName(kind) ++ ", but target " ++ @tagName(target) ++ " does not provide it");
    };
}

/// Decorate an Endpoint without cloning its route/OpenAPI metadata.
pub fn Requires(comptime EndpointType: type, comptime required: []const Kind) type {
    return struct {
        pub const http_method = EndpointType.http_method;
        pub const route_path = EndpointType.route_path;
        pub const handle = EndpointType.handle;
        pub const meta = EndpointType.meta;
        pub const required_capabilities = required;

        pub fn register(app: anytype) !void {
            return EndpointType.register(app);
        }
    };
}

test "capability set" {
    const testing = @import("std").testing;
    try testing.expect(!(Set{ .workers = false }).supports(.workers));
}
