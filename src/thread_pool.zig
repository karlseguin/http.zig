const std = @import("std");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

pub const Opts = struct {
    count: u32,
    backlog: u32,
};

pub fn ThreadPool(comptime F: anytype) type {
    const Args = std.meta.ArgsTuple(@TypeOf(F));
    return struct {
        stop: bool,
        push: usize,
        pull: usize,
        pending: usize,
        queue: []Args,
        threads: []Thread,
        mutex: Thread.Mutex,
        sem: Thread.Semaphore,
        cond: Thread.Condition,
        queue_end: usize,

        const Self = @This();

        pub fn init(allocator: Allocator, opts: Opts) !*Self {
            const queue = try allocator.alloc(Args, opts.backlog);
            errdefer allocator.free(queue);

            const threads = try allocator.alloc(Thread, opts.count);
            errdefer allocator.free(threads);

            const thread_pool = try allocator.create(Self);
            errdefer allocator.destroy(thread_pool);

            thread_pool.* = .{
                .pull = 0,
                .push = 0,
                .pending = 0,
                .cond = .{},
                .mutex = .{},
                .stop = false,
                .threads = threads,
                .queue = queue,
                .queue_end = queue.len - 1,
                .sem = .{ .permits = queue.len },
            };

            var started: usize = 0;
            errdefer {
                thread_pool.stop = true;
                thread_pool.cond.broadcast();
                for (0..started) |i| {
                    threads[i].join();
                }
            }

            for (0..threads.len) |i| {
                threads[i] = try Thread.spawn(.{}, Self.worker, .{thread_pool});
                started += 1;
            }

            return thread_pool;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.mutex.lock();
            self.stop = true;
            self.mutex.unlock();

            self.cond.broadcast();
            for (self.threads) |thrd| {
                thrd.join();
            }
            allocator.free(self.threads);
            allocator.free(self.queue);

            allocator.destroy(self);
        }

        pub fn empty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.pull == self.push;
        }

        pub fn spawn(self: *Self, args: Args) !void {
            self.sem.wait();
            self.mutex.lock();
            const push = self.push;
            self.queue[push] = args;
            self.push = if (push == self.queue_end) 0 else push + 1;
            self.pending += 1;
            self.mutex.unlock();
            self.cond.signal();
        }

        fn worker(self: *Self) void {
            while (true) {
                self.mutex.lock();
                while (self.pending == 0) {
                    if (self.stop) {
                        self.mutex.unlock();
                        return;
                    }
                    self.cond.wait(&self.mutex);
                }
                const pull = self.pull;
                const args = self.queue[pull];
                self.pull = if (pull == self.queue_end) 0 else pull + 1;
                self.pending -= 1;
                self.mutex.unlock();
                self.sem.post();
                @call(.auto, F, args);
            }
        }
    };
}

const t = @import("t.zig");
test "ThreadPool: small fuzz" {
    testSum = 0; // global defined near the end of this file
    var tp = try ThreadPool(testIncr).init(t.allocator, .{ .count = 3, .backlog = 3 });

    for (0..50_000) |_| {
        try tp.spawn(.{1});
    }
    while (tp.empty() == false) {
        std.time.sleep(std.time.ns_per_ms);
    }
    tp.deinit(t.allocator);
    try t.expectEqual(50_000, testSum);
}

test "ThreadPool: large fuzz" {
    testSum = 0; // global defined near the end of this file
    var tp = try ThreadPool(testIncr).init(t.allocator, .{ .count = 50, .backlog = 1000 });

    for (0..50_000) |_| {
        try tp.spawn(.{1});
    }
    while (tp.empty() == false) {
        std.time.sleep(std.time.ns_per_ms);
    }
    tp.deinit(t.allocator);
    try t.expectEqual(50_000, testSum);
}

var testSum: u64 = 0;
fn testIncr(c: u64) void {
    _ = @atomicRmw(u64, &testSum, .Add, c, .monotonic);
}
