//! Typed management-command dispatch shared by generated runners.
const std = @import("std");

pub fn Command(comptime Context: type) type {
    return struct {
        name: []const u8,
        summary: []const u8 = "",
        run: *const fn (context: *Context, args: []const [:0]const u8) anyerror!void,
    };
}

pub fn run(comptime Context: type, commands: []const Command(Context), context: *Context, args: []const [:0]const u8) !void {
    if (args.len == 0) return error.MissingRunnerCommand;
    const name = std.mem.sliceTo(args[0], 0);
    for (commands) |command| if (std.mem.eql(u8, command.name, name)) return command.run(context, args[1..]);
    return error.UnknownRunnerCommand;
}

test "typed management command dispatch" {
    const State = struct { called: bool = false };
    const Commands = struct {
        fn hello(state: *State, _: []const [:0]const u8) !void {
            state.called = true;
        }
    };
    var state: State = .{};
    const args = [_][:0]const u8{"hello"};
    try run(State, &.{.{ .name = "hello", .run = Commands.hello }}, &state, &args);
    try std.testing.expect(state.called);
}
