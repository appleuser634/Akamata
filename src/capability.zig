//! Package capability declarations checked against deployment targets.
pub const Target = enum { native, workers, containers };

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

test "capability set" {
    const testing = @import("std").testing;
    try testing.expect(!(Set{ .workers = false }).supports(.workers));
}
