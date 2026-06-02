const std = @import("std");
const am = @import("akamata");
const Hub = @import("ws_hub.zig").Hub;

pub const App = struct {
    db: am.db.Db,
    hub: Hub,
};
