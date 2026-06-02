// Legacy Ctx(App) for backward compatibility with examples/chat (old API).
// New code should use src/context.zig's Context(State) instead.

const std = @import("std");
const req_mod = @import("http/request.zig");
const res_mod = @import("http/response.zig");
const ctx_mod = @import("context.zig");

pub const Params = ctx_mod.Params;
pub const ParamError = ctx_mod.ParamError;

pub fn Ctx(comptime App: type) type {
    return struct {
        const Self = @This();

        app: *App,
        req: *req_mod.Request,
        res: *res_mod.Response,
        arena: std.mem.Allocator,
        params: Params = .{},
        stream_ptr: ?*anyopaque = null,
        io_ptr: ?*anyopaque = null,
        user_data: ?*anyopaque = null,

        pub fn json(self: *Self, code: u16, value: anytype) !void {
            self.res.setStatus(code);
            try self.res.json(value);
        }

        pub fn text(self: *Self, code: u16, content: []const u8) !void {
            self.res.setStatus(code);
            try self.res.text(content);
        }

        pub fn status(self: *Self, code: u16) void {
            self.res.setStatus(code);
        }
    };
}
