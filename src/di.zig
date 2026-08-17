//! Small, type-safe dependency container suitable for app/request scopes.
const std = @import("std");

pub const Scope = enum { application, request };

pub fn Provider(comptime T: type, comptime scope: Scope, comptime dependencies: []const type) type {
    return struct {
        pub const Value = T;
        pub const provider_scope = scope;
        pub const deps = dependencies;
    };
}

/// Validate duplicate, missing, and scope-invalid dependencies at comptime.
pub fn validate(comptime providers: []const type) void {
    inline for (providers, 0..) |P, i| {
        inline for (providers[0..i]) |Before| {
            if (P.Value == Before.Value) @compileError("duplicate dependency provider: " ++ @typeName(P.Value));
        }
        inline for (P.deps) |Dep| {
            comptime var found = false;
            comptime var dep_scope: Scope = .application;
            inline for (providers) |Candidate| if (Candidate.Value == Dep) {
                found = true;
                dep_scope = Candidate.provider_scope;
            };
            if (!found) @compileError("missing dependency provider: " ++ @typeName(Dep));
            if (P.provider_scope == .application and dep_scope == .request)
                @compileError("application-scoped providers cannot depend on request-scoped values");
        }
    }
    inline for (providers, 0..) |_, i| {
        comptime var visiting = [_]bool{false} ** providers.len;
        comptime var visited = [_]bool{false} ** providers.len;
        detectCycle(providers, i, &visiting, &visited);
    }
}

fn detectCycle(
    comptime providers: []const type,
    comptime index: usize,
    comptime visiting: *[providers.len]bool,
    comptime visited: *[providers.len]bool,
) void {
    if (visiting[index]) @compileError("dependency cycle includes " ++ @typeName(providers[index].Value));
    if (visited[index]) return;
    visiting[index] = true;
    inline for (providers[index].deps) |Dep| {
        comptime var dependency_index: ?usize = null;
        inline for (providers, 0..) |Candidate, candidate_index| {
            if (Candidate.Value == Dep) dependency_index = candidate_index;
        }
        if (dependency_index) |next| detectCycle(providers, next, visiting, visited);
    }
    visiting[index] = false;
    visited[index] = true;
}

/// A validated dependency graph. `order` is a dependency-first topological
/// order generated at comptime and can drive explicit application/request
/// construction without a runtime service locator.
pub fn Graph(comptime providers: []const type) type {
    comptime validate(providers);
    return struct {
        pub const provider_count = providers.len;
        pub const order = topologicalOrder(providers);
        pub const Services = Registry(valueTypes(providers));
    };
}

fn valueTypes(comptime providers: []const type) [providers.len]type {
    var result: [providers.len]type = undefined;
    for (providers, 0..) |P, i| result[i] = P.Value;
    return result;
}

fn topologicalOrder(comptime providers: []const type) [providers.len]usize {
    var result: [providers.len]usize = undefined;
    var emitted = [_]bool{false} ** providers.len;
    var count: usize = 0;
    while (count < providers.len) {
        var progress = false;
        for (providers, 0..) |P, i| {
            if (emitted[i]) continue;
            var ready = true;
            for (P.deps) |Dep| {
                for (providers, 0..) |Candidate, candidate_index| if (Candidate.Value == Dep and !emitted[candidate_index]) {
                    ready = false;
                };
            }
            if (ready) {
                result[count] = i;
                emitted[i] = true;
                count += 1;
                progress = true;
            }
        }
        if (!progress) unreachable; // validate() emitted the useful cycle diagnostic.
    }
    return result;
}

/// A zero-allocation typed registry. Values remain owned by the caller.
pub fn Registry(comptime Types: []const type) type {
    return struct {
        const Self = @This();
        values: std.meta.Tuple(pointerTypes(Types)) = undefined,
        present: [Types.len]bool = @splat(false),

        pub fn provide(self: *Self, comptime T: type, value: *T) void {
            const i = comptime indexOf(Types, T);
            self.values[i] = value;
            self.present[i] = true;
        }
        pub fn get(self: *Self, comptime T: type) !*T {
            const i = comptime indexOf(Types, T);
            if (!self.present[i]) return error.DependencyNotProvided;
            return self.values[i];
        }
    };
}

fn pointerTypes(comptime types: []const type) [types.len]type {
    var out: [types.len]type = undefined;
    for (types, 0..) |T, i| out[i] = *T;
    return out;
}
fn indexOf(comptime types: []const type, comptime T: type) usize {
    for (types, 0..) |Candidate, i| if (Candidate == T) return i;
    @compileError("dependency is not part of this registry: " ++ @typeName(T));
}

test "typed registry" {
    const R = Registry(&.{ u32, bool });
    var r: R = .{};
    var n: u32 = 7;
    r.provide(u32, &n);
    try std.testing.expectEqual(@as(u32, 7), (try r.get(u32)).*);
    try std.testing.expectError(error.DependencyNotProvided, r.get(bool));
}
