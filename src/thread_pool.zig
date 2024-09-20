const std = @import("std");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    count: u32,
    backlog: u32,
    buffer_size: usize,
};

pub fn ThreadPool(comptime F: anytype) type {
    // When the worker thread calls F, it'll inject its static buffer.
    // So F would be: handle(server: *Server, conn: *Conn, buf: []u8)
    // and FullArgs would be our 3 args....
    const FullArgs = std.meta.ArgsTuple(@TypeOf(F));
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

    var fields: [ARG_COUNT]std.builtin.Type.StructField = undefined;
    inline for (full_fields[0..ARG_COUNT], 0..) |field, index| fields[index] = field;

    const Args = comptime @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .is_tuple = true,
            .fields = &fields,
            .decls = &.{},
        },
    });

    return struct {
        // position in queue to read from
        tail: usize,

        // position in the queue to write to
        head: usize,

        // pendind jobs
        queue: []Args,

        stopped: bool,
        threads: []Thread,
        mutex: Thread.Mutex,
        read_cond: Thread.Condition,
        write_cond: Thread.Condition,

        const Self = @This();

        // we expect allocator to be an Arena
        pub fn init(allocator: Allocator, opts: Opts) !*Self {
            const queue = try allocator.alloc(Args, if (opts.backlog == 0 or opts.backlog == 1) 2 else opts.backlog);
            const threads = try allocator.alloc(Thread, opts.count);
            const thread_pool = try allocator.create(Self);

            thread_pool.* = .{
                .tail = 0,
                .head = 0,
                .mutex = .{},
                .stopped = false,
                .queue = queue,
                .read_cond = .{},
                .write_cond = .{},
                .threads = threads,
            };

            var started: usize = 0;
            errdefer {
                thread_pool.stopped = true;
                thread_pool.read_cond.broadcast();
                for (0..started) |i| {
                    threads[i].join();
                }
            }

            for (0..threads.len) |i| {
                const buffer = try allocator.alloc(u8, opts.buffer_size);
                threads[i] = try Thread.spawn(.{}, Self.worker, .{ thread_pool, buffer });
                started += 1;
            }

            return thread_pool;
        }

        pub fn stop(self: *Self) void {
            {
                // allow stop to be called as part of server.stop()
                // but also in server.deinit(), or in both.
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.stopped) {
                    return;
                }
                self.stopped = true;
            }

            self.read_cond.broadcast();
            for (self.threads) |thrd| {
                thrd.join();
            }
        }

        pub fn empty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.head == self.tail;
        }

        pub fn spawn(self: *Self, args: []const Args) void {
            var pending = args;
            var capacity: usize = 0;

            const queue = self.queue;
            const queue_end  = queue.len - 1;

            while (true) {
                self.mutex.lock();
                var head = self.head;
                var tail = self.tail;
                while (true) {
                    capacity = if (head < tail) tail - head - 1 else queue_end - head + tail;
                    if (capacity > 0) {
                        break;
                    }
                    self.write_cond.wait(&self.mutex);
                    head = self.head;
                    tail = self.tail;
                }

                const ready = if (capacity >= pending.len) pending else pending[0..capacity];
                for (ready) |a| {
                    queue[head] = a;
                    head = if (head == queue_end) 0 else head + 1;
                }
                self.head = head;
                self.mutex.unlock();
                self.read_cond.signal();
                if (ready.len == pending.len) {
                    break;
                }
                pending = pending[ready.len..];
            }
        }

        // Having a re-usable buffer per thread is the most efficient way
        // we can do any dynamic allocations. We'll pair this later with
        // a FallbackAllocator. The main issue is that some data must outlive
        // the worker thread (in nonblocking mode), but this isn't something
        // we need to worry about here. As far as this worker thread is
        // concerned, it has a chunk of memory (buffer) which it'll pass
        // to the callback function to do with as it wants.
        fn worker(self: *Self, buffer: []u8) void {
            const queue = self.queue;
            const queue_end = queue.len - 1;

            while (true) {
                self.mutex.lock();
                while (self.tail == self.head) {
                    if (self.stopped) {
                        self.mutex.unlock();
                        return;
                    }
                    self.read_cond.wait(&self.mutex);
                }
                const tail = self.tail;
                const args = queue[tail];
                self.tail = if (tail == queue_end) 0 else tail + 1;
                self.mutex.unlock();
                self.write_cond.signal();

                // convert Args to FullArgs, i.e. inject buffer as the last argument
                var full_args: FullArgs = undefined;
                full_args[ARG_COUNT] = buffer;
                inline for (0..ARG_COUNT) |i| {
                    full_args[i] = args[i];
                }
                @call(.auto, F, full_args);
            }
        }
    };
}

const t = @import("t.zig");
test "ThreadPool: batch add" {
    defer t.reset();

    const counts = [_]u32{1, 2, 3, 4, 5, 6};
    const backlogs = [_]u32{1, 2, 3, 4, 5, 6};
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
            var tp = try ThreadPool(testIncr).init(t.arena.allocator(), .{ .count = count, .backlog = backlog, .buffer_size = 512 });

            for (0..1_000) |_| {
                tp.spawn(&.{.{1}, .{2}, .{3}, .{4}});
            }
            while (tp.empty() == false) {
                std.time.sleep(std.time.ns_per_ms);
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
    var tp = try ThreadPool(testIncr).init(t.arena.allocator(), .{ .count = 3, .backlog = 3, .buffer_size = 512 });

    for (0..10_000) |_| {
        tp.spawn(&.{.{1}, .{2}, .{3}});
    }
    while (tp.empty() == false) {
        std.time.sleep(std.time.ns_per_ms);
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
    var tp = try ThreadPool(testIncr).init(t.arena.allocator(), .{ .count = 50, .backlog = 1000, .buffer_size = 512 });

    for (0..10_000) |_| {
        tp.spawn(&.{.{1}, .{2}});
        tp.spawn(&.{.{3}});
        tp.spawn(&.{.{4}, .{5}, .{6}});
    }
    while (tp.empty() == false) {
        std.time.sleep(std.time.ns_per_ms);
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
    std.time.sleep(std.time.ns_per_us * 20);
}
