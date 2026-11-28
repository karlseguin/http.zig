const std = @import("std");

const Io = std.Io;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    count: u32,
    backlog: u32,
    buffer_size: usize,
};

pub fn ThreadPool(comptime F: anytype) type {
    const BATCH_SIZE = 16;

    // When the worker thread calls F, it'll inject its static buffer.
    // So F would be: handle(server: *Server, conn: *Conn, buf: []u8)
    // and FullArgs would be our 3 args....
    const FullArgs = std.meta.ArgsTuple(@TypeOf(F));
    const Args = SpawnArgs(FullArgs);
    return struct {
        stopped: bool,
        threads: []Thread,
        arena: std.heap.ArenaAllocator,

        // One queue for every worker thread. With a queue per worker, a job put on the
        // queue of a worker that is running a long job waits for that job to end, however
        // many other workers are idle.
        shared: *Shared,

        // we queue jobs here before batching them to the workers. We do this
        // to minimze the amount of locking we need to do.
        batch: [BATCH_SIZE]Args,
        batch_size: usize,

        const Self = @This();

        const Shared = struct {
            io: Io,
            // position in queue to read from
            tail: usize,
            // position in the queue to write to
            head: usize,
            // pending jobs
            queue: []Args,
            stopped: bool,
            mutex: Io.Mutex,
            read_cond: Io.Condition,
            write_cond: Io.Condition,

            fn push(self: *Shared, args: []const Args) void {
                const io = self.io;
                var pending = args;
                var capacity: usize = 0;

                const queue = self.queue;
                const queue_end = queue.len - 1;

                while (true) {
                    self.mutex.lockUncancelable(io);
                    var head = self.head;
                    var tail = self.tail;
                    while (true) {
                        capacity = if (head < tail) tail - head - 1 else queue_end - head + tail;
                        if (capacity > 0) {
                            break;
                        }
                        self.write_cond.waitUncancelable(io, &self.mutex);
                        head = self.head;
                        tail = self.tail;
                    }

                    const ready = if (capacity >= pending.len) pending else pending[0..capacity];
                    for (ready) |a| {
                        queue[head] = a;
                        head = if (head == queue_end) 0 else head + 1;
                    }
                    self.head = head;
                    self.mutex.unlock(io);
                    if (ready.len <= 4) {
                        // For a few jobs, wake only as many workers as we have jobs
                        // rather than having every idle worker wake up, fight over
                        // the mutex and go back to sleep.
                        for (0..ready.len) |_| self.read_cond.signal(io);
                    } else {
                        self.read_cond.broadcast(io);
                    }
                    if (ready.len == pending.len) {
                        break;
                    }
                    pending = pending[ready.len..];
                }
            }

            fn getNext(self: *Shared) ?Args {
                const io = self.io;
                const queue = self.queue;
                const queue_end = queue.len - 1;

                self.mutex.lockUncancelable(io);
                while (self.tail == self.head) {
                    if (self.stopped) {
                        self.mutex.unlock(io);
                        return null;
                    }
                    self.read_cond.waitUncancelable(io, &self.mutex);
                }

                const tail = self.tail;
                const args = queue[tail];
                self.tail = if (tail == queue_end) 0 else tail + 1;
                self.mutex.unlock(io);
                self.write_cond.signal(io);
                return args;
            }

            // Having a re-usable buffer per thread is the most efficient way
            // we can do any dynamic allocations. As far as a worker thread is
            // concerned, it has a chunk of memory (buffer) which it'll pass
            // to the callback function to do with as it wants.
            fn run(self: *Shared, buffer: []u8) void {
                while (true) {
                    const args = self.getNext() orelse return;

                    // convert Args to FullArgs, i.e. inject buffer as the last argument
                    var full_args: FullArgs = undefined;
                    const ARG_COUNT = std.meta.fields(FullArgs).len - 1;
                    full_args[ARG_COUNT] = buffer;
                    inline for (0..ARG_COUNT) |i| {
                        full_args[i] = args[i];
                    }
                    @call(.auto, F, full_args);
                }
            }
        };

        // we expect allocator to be an Arena
        pub fn init(io: Io, allocator: Allocator, opts: Opts) !Self {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const aa = arena.allocator();

            const threads = try aa.alloc(Thread, opts.count);
            const shared = try aa.create(Shared);
            shared.* = .{
                .io = io,
                .tail = 0,
                .head = 0,
                .queue = try aa.alloc(Args, if (opts.backlog == 0 or opts.backlog == 1) 2 else opts.backlog),
                .stopped = false,
                .mutex = .init,
                .read_cond = .init,
                .write_cond = .init,
            };

            var started: usize = 0;
            errdefer {
                shared.mutex.lockUncancelable(io);
                shared.stopped = true;
                shared.mutex.unlock(io);
                shared.read_cond.broadcast(io);
                for (0..started) |i| threads[i].join();
            }

            for (0..threads.len) |i| {
                const buffer = try aa.alloc(u8, opts.buffer_size);
                threads[i] = try Thread.spawn(.{}, Shared.run, .{ shared, buffer });
                started += 1;
            }

            return .{
                .arena = arena,
                .stopped = false,
                .shared = shared,
                .threads = threads,
                .batch = undefined,
                .batch_size = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn stop(self: *Self) void {
            if (@atomicRmw(bool, &self.stopped, .Xchg, true, .monotonic) == true) {
                return;
            }

            const shared = self.shared;
            const io = shared.io;
            shared.mutex.lockUncancelable(io);
            shared.stopped = true;
            shared.mutex.unlock(io);
            shared.read_cond.broadcast(io);
            for (self.threads) |*thread| {
                thread.join();
            }
        }

        pub fn spawn(self: *Self, args: Args) void {
            var i = self.batch_size;
            self.batch[i] = args;
            i += 1;

            if (i == BATCH_SIZE) {
                self.flush(i);
                i = 0;
            }
            self.batch_size = i;
        }

        pub fn spawnOne(self: *Self, args: Args) void {
            self.shared.push(&.{args});
        }

        pub fn flush(self: *Self, batch_size: usize) void {
            self.batch_size = 0;
            self.shared.push(self.batch[0..batch_size]);
        }

        pub fn empty(self: *Self) bool {
            const shared = self.shared;
            const io = shared.io;
            shared.mutex.lockUncancelable(io);
            defer shared.mutex.unlock(io);
            return shared.head == shared.tail;
        }
    };
}

fn SpawnArgs(FullArgs: anytype) type {
    const full_fields = std.meta.fields(FullArgs);
    const ARG_COUNT = full_fields.len - 1;

    // Args will be FullArgs[0..len-1], so in the above example, args would be
    // (*Server, *Conn)
    // Args is what we expect the caller to pass to spawn. The worker thread
    // will convert an Args into FullArgs by injecting its static buffer as
    // the final argument.

    // TODO: We could verify that the last argument to FullArgs is, in fact, a
    // []u8. But this ThreadPool is private and being used for 2 specific cases
    // that we control.

    var field_types: [ARG_COUNT]type = undefined;
    inline for (full_fields[0..ARG_COUNT], 0..) |field, i| {
        field_types[i] = field.type;
    }
    return @Tuple(&field_types);
}

const t = @import("t.zig");
test "ThreadPool: batch add" {
    defer t.reset();

    const counts = [_]u32{ 1, 2, 3, 4, 5, 6 };
    const backlogs = [_]u32{ 1, 2, 3, 4, 5, 6 };
    for (counts) |count| {
        for (backlogs) |backlog| {
            testSum = 0; // global defined near the end of this file
            testCount = 0; // global defined near the end of this file
            testC1 = 0;
            testC2 = 0;
            testC3 = 0;
            testC4 = 0;
            testC5 = 0;
            testC6 = 0;
            var tp = try ThreadPool(testIncr).init(t.io, t.arena.allocator(), .{ .count = count, .backlog = backlog, .buffer_size = 512 });
            defer tp.deinit();

            for (0..1_000) |_| {
                tp.spawn(.{1});
                tp.spawn(.{2});
                tp.spawn(.{3});
                tp.spawn(.{4});
            }
            while (tp.empty() == false) {
                try t.io.sleep(.fromMilliseconds(1), .awake);
            }
            tp.stop();
            try t.expectEqual(10_000, testSum);
            try t.expectEqual(4_000, testCount);

            try t.expectEqual(1000, testC1);
            try t.expectEqual(1000, testC2);
            try t.expectEqual(1000, testC3);
            try t.expectEqual(1000, testC4);
            try t.expectEqual(0, testC5);
            try t.expectEqual(0, testC6);
        }
    }
}

test "ThreadPool: small fuzz" {
    defer t.reset();

    testSum = 0; // global defined near the end of this file
    testCount = 0; // global defined near the end of this file
    testC1 = 0;
    testC2 = 0;
    testC3 = 0;
    testC4 = 0;
    testC5 = 0;
    testC6 = 0;
    var tp = try ThreadPool(testIncr).init(t.io, t.arena.allocator(), .{ .count = 3, .backlog = 3, .buffer_size = 512 });
    defer tp.deinit();

    for (0..10_000) |_| {
        tp.spawn(.{1});
        tp.spawn(.{2});
        tp.spawn(.{3});
    }
    while (tp.empty() == false) {
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
    tp.stop();
    try t.expectEqual(60_000, testSum);
    try t.expectEqual(30_000, testCount);
    try t.expectEqual(10_000, testC1);
    try t.expectEqual(10_000, testC2);
    try t.expectEqual(10_000, testC3);
    try t.expectEqual(0, testC4);
    try t.expectEqual(0, testC5);
    try t.expectEqual(0, testC6);
}

test "ThreadPool: large fuzz" {
    defer t.reset();

    testSum = 0; // global defined near the end of this file
    testCount = 0; // global defined near the end of this file
    testC1 = 0;
    testC2 = 0;
    testC3 = 0;
    testC4 = 0;
    testC5 = 0;
    testC6 = 0;
    var tp = try ThreadPool(testIncr).init(t.io, t.arena.allocator(), .{ .count = 50, .backlog = 1000, .buffer_size = 512 });
    defer tp.deinit();

    for (0..10_000) |_| {
        tp.spawn(.{1});
        tp.spawn(.{2});
        tp.spawn(.{3});
        tp.spawn(.{4});
        tp.spawn(.{5});
        tp.spawn(.{6});
    }
    while (tp.empty() == false) {
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
    tp.stop();
    try t.expectEqual(210_000, testSum);
    try t.expectEqual(60_000, testCount);
    try t.expectEqual(10_000, testC1);
    try t.expectEqual(10_000, testC2);
    try t.expectEqual(10_000, testC3);
    try t.expectEqual(10_000, testC4);
    try t.expectEqual(10_000, testC5);
    try t.expectEqual(10_000, testC6);
}

var testSum: u64 = 0;
var testCount: u64 = 0;
var testC1: u64 = 0;
var testC2: u64 = 0;
var testC3: u64 = 0;
var testC4: u64 = 0;
var testC5: u64 = 0;
var testC6: u64 = 0;
fn testIncr(c: u64, buf: []u8) void {
    std.debug.assert(buf.len == 512);
    _ = @atomicRmw(u64, &testSum, .Add, c, .monotonic);
    _ = @atomicRmw(u64, &testCount, .Add, 1, .monotonic);
    switch (c) {
        1 => _ = @atomicRmw(u64, &testC1, .Add, 1, .monotonic),
        2 => _ = @atomicRmw(u64, &testC2, .Add, 1, .monotonic),
        3 => _ = @atomicRmw(u64, &testC3, .Add, 1, .monotonic),
        4 => _ = @atomicRmw(u64, &testC4, .Add, 1, .monotonic),
        5 => _ = @atomicRmw(u64, &testC5, .Add, 1, .monotonic),
        6 => _ = @atomicRmw(u64, &testC6, .Add, 1, .monotonic),
        else => unreachable,
    }
    // let the threadpool queue get backed up
    t.io.sleep(.fromMicroseconds(20), .awake) catch unreachable;
}

test "ThreadPool: a long job does not hold up the jobs behind it" {
    defer t.reset();

    testBlockerRelease = .{};
    testBlockerStarted = .{};
    testQuickCount = 0;
    var tp = try ThreadPool(testBlockOrCount).init(t.io, t.arena.allocator(), .{ .count = 4, .backlog = 64, .buffer_size = 512 });
    defer tp.deinit();
    // Runs before deinit, including when an expectation fails: release the
    // blocked worker and join every thread before the arena is freed.
    defer {
        testBlockerRelease.post(t.io);
        tp.stop();
    }

    // One worker is busy for as long as the test likes
    tp.spawnOne(.{true});
    testBlockerStarted.waitUncancelable(t.io);

    // Every other job is done meanwhile, whichever worker it would once have been queued behind
    for (0..32) |_| tp.spawnOne(.{false});
    var waited_ms: u64 = 0;
    while (@atomicLoad(u64, &testQuickCount, .monotonic) < 32 and waited_ms < 5_000) : (waited_ms += 1) {
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
    try t.expectEqual(32, @atomicLoad(u64, &testQuickCount, .monotonic));
}

var testBlockerRelease: Io.Semaphore = .{};
var testBlockerStarted: Io.Semaphore = .{};
var testQuickCount: u64 = 0;
fn testBlockOrCount(block: bool, _: []u8) void {
    if (block) {
        testBlockerStarted.post(t.io);
        testBlockerRelease.waitUncancelable(t.io);
    } else {
        _ = @atomicRmw(u64, &testQuickCount, .Add, 1, .monotonic);
    }
}
