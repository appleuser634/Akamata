const am = @import("akamata");

/// Per-user WS hub keyed by user_id (string). The framework hub handles
/// dupe/free of the key and connection-list lifetimes; on Workers this
/// becomes a no-op stub and the JS host routes WS to the `UserHub`
/// Durable Object instead.
pub const Hub = am.ws.Hub([]const u8);
