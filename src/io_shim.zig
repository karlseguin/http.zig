/// Process-local Io shim for vendored httpz (and transitively websocket/metrics).
///
/// Zig 0.16's `std.Io` abstraction replaces `std.Thread.Mutex/Condition/sleep`
/// with Io-aware equivalents that take `io: std.Io` as an argument. httpz's
/// internal threading touches Mutex extensively. Rather than thread `io`
/// through every vendored callsite (huge churn across ~5 files), this shim
/// lazy-initializes a `std.Io.Threaded` on first access and caches the
/// derived `Io`. One Threaded per process, safe for httpz's internal use.
///
/// This shim is a separate Io instance from the host application's — but
/// that's fine for the `std.Io.Mutex` use case: a Mutex instance is locked
/// and unlocked with a consistent `io` (whichever one httpz owns); the host
/// application's Mutexes use their own `io`.
const std = @import("std");

var threaded: std.Io.Threaded = undefined;
var init_done: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

pub fn stdio() std.Io {
    // Simple init-once via atomic CAS. 0 = uninit, 1 = initializing, 2 = ready.
    while (true) {
        const st = init_done.load(.acquire);
        if (st == 2) break;
        if (st == 0 and init_done.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
            init_done.store(2, .release);
            break;
        }
        // Spin while another thread initializes. Brief.
        std.atomic.spinLoopHint();
    }
    return threaded.io();
}
