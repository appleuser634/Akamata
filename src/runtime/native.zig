const std = @import("std");

/// Run a server until the OS terminates the process. Signal-based graceful
/// shutdown was deliberately not wired up against std.posix.Sigaction in 0.16
/// because the handler signature became architecture-specific; the harness
/// kill / Ctrl-C still works to stop the process. Callers that need cooperative
/// shutdown can call `server.requestShutdown()` from another thread.
pub fn run(comptime ServerT: type, server: *ServerT) !void {
    return server.run();
}
