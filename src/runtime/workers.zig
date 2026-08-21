const std = @import("std");
const builtin = @import("builtin");

// Workers/WASM runtime: exposes a minimal ABI for the JS host (deploy/worker/index.mjs)
// to invoke Zig handlers without WASI. The host:
//   1. allocates a buffer via `alloc(len)` and copies request bytes in,
//   2. calls `handle_fetch(ptr, len)` which returns a packed pointer to a
//      response buffer it must read (length via `last_response_length()`),
//   3. calls `dealloc(ptr, len)` to free both buffers.
//
// User code provides the actual fetch dispatch via `setDispatch`. The pointer
// is stored at startup via the `akamata_init` export and exposed for the wasm host.

pub const FetchFn = *const fn (request_bytes: []const u8, out: *std.ArrayList(u8)) anyerror!void;

const page_alloc = std.heap.wasm_allocator;
var dispatch_ptr: ?FetchFn = null;
pub const QueueFn = *const fn (message_bytes: []const u8) anyerror!void;
var queue_dispatch_ptr: ?QueueFn = null;

pub fn setDispatch(f: FetchFn) void {
    dispatch_ptr = f;
}

pub fn setQueueDispatch(f: QueueFn) void {
    queue_dispatch_ptr = f;
}

export fn alloc(len: usize) usize {
    const buf = page_alloc.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

export fn dealloc(ptr: usize, len: usize) void {
    if (ptr == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    page_alloc.free(p[0..len]);
}

var last_response_ptr: usize = 0;
var last_response_len: usize = 0;
var last_error_name: []const u8 = "";

export fn handle_fetch(req_ptr: usize, req_len: usize) usize {
    last_error_name = "";
    if (req_ptr == 0) {
        last_error_name = "InvalidRequestPointer";
        return 0;
    }
    const p: [*]const u8 = @ptrFromInt(req_ptr);
    const req_bytes = p[0..req_len];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(page_alloc);
    if (dispatch_ptr) |d| {
        d(req_bytes, &out) catch |err| {
            last_error_name = @errorName(err);
            return 0;
        };
    } else {
        last_error_name = "DispatchNotRegistered";
        return 0;
    }
    const buf = page_alloc.alloc(u8, out.items.len) catch return 0;
    @memcpy(buf, out.items);
    last_response_ptr = @intFromPtr(buf.ptr);
    last_response_len = buf.len;
    return last_response_ptr;
}

export fn last_error_ptr() usize {
    return @intFromPtr(last_error_name.ptr);
}

export fn last_error_length() usize {
    return last_error_name.len;
}

export fn last_response_length() usize {
    return last_response_len;
}

/// Consume one serialized Cloudflare Queue message. A non-zero result asks
/// the JS handler to retry the message; successful messages are acknowledged.
export fn handle_queue(message_ptr: usize, message_len: usize) i32 {
    if (message_ptr == 0) return -1;
    const dispatch = queue_dispatch_ptr orelse return -2;
    const ptr: [*]const u8 = @ptrFromInt(message_ptr);
    dispatch(ptr[0..message_len]) catch return -1;
    return 0;
}

// === JS-side reentrancy support ===
//
// HTTP client and FCM access-token fetches are asynchronous on the JS side.
// To let synchronous-looking Zig code make these calls, we use a two-pass
// model: the JS host calls `handle_fetch` once to discover what async work
// is needed (via callbacks recorded in `pending_*` arrays exposed below),
// awaits everything, then calls `resume_fetch` with the resolved results.
//
// MVP keeps this stubbed; the deploy/worker/index.mjs side documents how to
// wire it up.

export fn pending_fetch_count() usize {
    return 0;
}

comptime {
    _ = builtin;
}
