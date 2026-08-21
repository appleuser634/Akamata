const am = @import("akamata");

pub const Principal = union(enum) { account: u64, client: am.BoundedString(64), service: am.BoundedString(64) };
pub const PersistentMessage = struct { id: u64, sender: []const u8, body: am.BoundedString(1024) };
pub const Signal = struct { session_id: am.BoundedString(64), value: u8 };
pub const PresenceChanged = struct { connections: u32 };
pub const RealtimeEvent = union(enum) { signal: Signal, presence: PresenceChanged };
pub const Protocol = am.events.Protocol(RealtimeEvent, 1);

pub const WorkersEnv = struct {
    db: am.binding.D1("DB"),
    rooms: am.binding.DurableObject("AKAMATA_REALTIME"),
    events: am.binding.Queue("EVENTS"),
    storage: am.binding.R2("FILES"),
    secret: am.binding.Secret("JWT_SECRET"),
};

comptime {
    am.binding.validate(WorkersEnv, .workers);
}
