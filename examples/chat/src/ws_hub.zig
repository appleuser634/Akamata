const am = @import("akamata");

/// Chat rooms are keyed by u64 (the SQLite row id). The framework hub
/// handles in-memory broadcast on native and turns into a no-op stub on
/// Workers, where the `ChatRoom` Durable Object owns broadcasting.
pub const Hub = am.ws.Hub(u64);
