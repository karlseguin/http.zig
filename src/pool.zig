const std = @import("std");
const t = @import("t.zig");

const Allocator = std.mem.Allocator;

pub fn Pool(comptime E: type, comptime S: type) type {
    const initFnPtr = *const fn (S) anyerror!E;

    return struct {
        items: []E,
        available: usize,
        allocator: Allocator,
        initFn: initFnPtr,
        initState: S,
        mutex: std.Thread.Mutex,

        const Self = @This();

        pub fn init(allocator: Allocator, size: usize, initFn: initFnPtr, initState: S) !Self {
            const items = try allocator.alloc(E, size);

            for (0..size) |i| {
                items[i] = try initFn(initState);
            }

            return Self{
                .items = items,
                .initFn = initFn,
                .initState = initState,
                .available = size,
                .allocator = allocator,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            for (self.items) |e| {
                e.deinit(allocator);
                allocator.destroy(e);
            }
            allocator.free(self.items);
        }

        pub fn acquire(self: *Self) !E {
            const items = self.items;
            self.mutex.lock();
            const available = self.available;
            if (available == 0) {
                self.mutex.unlock();
                return try self.initFn(self.initState);
            }
            defer self.mutex.unlock();
            const new_available = available - 1;
            self.available = new_available;
            return items[new_available];
        }

        pub fn release(self: *Self, e: E) void {
            const items = self.items;

            self.mutex.lock();
            const available = self.available;

            if (available == items.len) {
                self.mutex.unlock();
                const allocator = self.allocator;
                e.deinit(allocator);
                allocator.destroy(e);
                return;
            }

            defer self.mutex.unlock();
            items[available] = e;
            self.available = available + 1;
        }
    };
}

var id: i32 = 0;
const TestEntry = struct {
    id: i32,
    acquired: bool,
    deinited: bool,

    pub fn init(incr: i32) !*TestEntry {
        id += incr;
        var entry = try t.allocator.create(TestEntry);
        entry.id = id;
        entry.acquired = false;
        return entry;
    }

    pub fn deinit(self: *TestEntry, _: Allocator) void {
        self.deinited = true;
    }
};

test "pool: acquires & release" {
    id = 0;
    var p = try Pool(*TestEntry, i32).init(t.allocator, 2, TestEntry.init, 5);
    defer p.deinit();

    var e1 = try p.acquire();
    try t.expectEqual(@as(i32, 10), e1.id);
    try t.expectEqual(false, e1.deinited);

    var e2 = try p.acquire();
    try t.expectEqual(@as(i32, 5), e2.id);
    try t.expectEqual(false, e2.deinited);

    var e3 = try p.acquire();
    try t.expectEqual(@as(i32, 15), e3.id);
    try t.expectEqual(false, e3.deinited);

    // released first, so back in the pool
    p.release(e3);
    try t.expectEqual(@as(i32, 15), e3.id);
    try t.expectEqual(false, e3.deinited);

    p.release(e2);
    try t.expectEqual(@as(i32, 5), e2.id);
    try t.expectEqual(false, e2.deinited);

    p.release(e1);
    // TODO: how to test that e1 was properly released?
}

test "pool: threadsafety" {
    id = 0;
    var p = try Pool(*TestEntry, i32).init(t.allocator, 4, TestEntry.init, 1);
    defer p.deinit();

    const t1 = try std.Thread.spawn(.{}, testPool, .{&p});
    const t2 = try std.Thread.spawn(.{}, testPool, .{&p});
    const t3 = try std.Thread.spawn(.{}, testPool, .{&p});
    const t4 = try std.Thread.spawn(.{}, testPool, .{&p});
    const t5 = try std.Thread.spawn(.{}, testPool, .{&p});

    t1.join();
    t2.join();
    t3.join();
    t4.join();
    t5.join();
}

fn testPool(p: *Pool(*TestEntry, i32)) void {
    var r = t.getRandom();
    const random = r.random();

    for (0..5000) |_| {
        var e = p.acquire() catch unreachable;
        std.debug.assert(e.acquired == false);
        e.acquired = true;
        std.time.sleep(random.uintAtMost(u32, 100000));
        e.acquired = false;
        p.release(e);
    }
}
