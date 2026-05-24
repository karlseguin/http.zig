const std = @import("std");
const metrics = @import("metrics.zig");
const blockingMode = @import("httpz.zig").blockingMode;

const Io = std.Io;
const Mutex = Io.Mutex;
const Allocator = std.mem.Allocator;

pub const Buffer = struct {
    data: []u8,
    type: Type,

    const Type = enum {
        arena,
        static,
        pooled,
        dynamic,
    };
};

pub const Pool = struct {
    io: Io,
    mutex: Mutex,
    available: usize,
    buffers: []Buffer,
    allocator: Allocator,
    buffer_size: usize,

    pub fn init(io: Io, allocator: Allocator, count: usize, buffer_size: usize) !Pool {
        const buffers = try allocator.alloc(Buffer, count);
        errdefer allocator.free(buffers);

        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| {
                allocator.free(buffers[i].data);
            }
        }

        for (0..count) |i| {
            buffers[i] = .{
                .type = .pooled,
                .data = try allocator.alloc(u8, buffer_size),
            };
            initialized += 1;
        }

        return .{
            .io = io,
            .mutex = .init,
            .buffers = buffers,
            .available = count,
            .allocator = allocator,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *Pool) void {
        const allocator = self.allocator;
        for (self.buffers) |buf| {
            allocator.free(buf.data);
        }
        allocator.free(self.buffers);
    }

    pub fn static(self: Pool, size: usize) !Buffer {
        return .{
            .type = .static,
            .data = try self.allocator.alloc(u8, size),
        };
    }

    pub fn alloc(self: *Pool, size: usize) !Buffer {
        return self.allocType(self.allocator, .dynamic, size);
    }

    pub fn arenaAlloc(self: *Pool, arena: Allocator, size: usize) !Buffer {
        return self.allocType(arena, .arena, size);
    }

    // Returns a pooled buffer, or null if the pool is empty. Never falls back
    // to allocating. Useful when the caller wants to use the pool as a hot path
    // and handle the empty case with a different strategy.
    pub fn tryAlloc(self: *Pool) ?Buffer {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const available = self.available;
        if (available == 0) {
            return null;
        }
        const index = available - 1;
        const buffer = self.buffers[index];
        self.available = index;
        return buffer;
    }

    fn allocType(self: *Pool, allocator: Allocator, buffer_type: Buffer.Type, size: usize) !Buffer {
        if (size > self.buffer_size) {
            metrics.allocBufferLarge(size);
            return .{
                .type = buffer_type,
                .data = try allocator.alloc(u8, size),
            };
        }

        self.mutex.lockUncancelable(self.io);
        const available = self.available;
        if (available == 0) {
            self.mutex.unlock(self.io);
            metrics.allocBufferEmpty(size);
            return .{
                .type = buffer_type,
                .data = try allocator.alloc(u8, size),
            };
        }
        defer self.mutex.unlock(self.io);

        const index = available - 1;
        const buffer = self.buffers[index];
        self.available = index;
        return buffer;
    }

    pub fn free(self: *Pool, buffer: Buffer) void {
        switch (buffer.type) {
            .arena => {},
            .pooled => self.release(buffer),
            .static => self.allocator.free(buffer.data),
            .dynamic => self.allocator.free(buffer.data),
        }
    }

    pub fn release(self: *Pool, buffer: Buffer) void {
        switch (buffer.type) {
            .static, .arena => {},
            .dynamic => self.allocator.free(buffer.data),
            .pooled => {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const available = self.available;
                self.buffers[available] = buffer;
                self.available = available + 1;
            },
        }
    }
};

const t = @import("t.zig");

test "BufferPool race" {
    if (comptime blockingMode()) return error.SkipZigTest;

    var pool = try Pool.init(t.io, t.allocator, 1, 64);
    defer pool.deinit();

    const Ctx = struct {
        fn worker(p: *Pool) void {
            var i: usize = 0;
            while (i < 500_000) : (i += 1) {
                const buf = p.tryAlloc() orelse continue;
                std.atomic.spinLoopHint();
                p.release(buf);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thr| thr.* = try std.Thread.spawn(.{}, Ctx.worker, .{&pool});
    for (&threads) |*thr| thr.join();
}

test "BufferPool" {
    var pool = try Pool.init(t.io, t.allocator, 2, 10);
    defer pool.deinit();

    {
        // bigger than our buffers in pool
        const buffer = try pool.alloc(11);
        defer pool.release(buffer);
        try t.expectEqual(.dynamic, buffer.type);
        try t.expectEqual(11, buffer.data.len);
    }

    {
        // smaller than our buffers in pool
        const buf1 = try pool.alloc(4);
        try t.expectEqual(.pooled, buf1.type);
        try t.expectEqual(10, buf1.data.len);

        const buf2 = try pool.alloc(5);
        try t.expectEqual(.pooled, buf2.type);
        try t.expectEqual(10, buf2.data.len);

        try t.expectEqual(false, &buf1.data[0] == &buf2.data[0]);

        // no more buffers in the pool, creates a dynamic buffer
        const buf3 = try pool.alloc(6);
        try t.expectEqual(.dynamic, buf3.type);
        try t.expectEqual(6, buf3.data.len);

        pool.release(buf1);

        // now has items!
        const buf4 = try pool.alloc(6);
        try t.expectEqual(.pooled, buf4.type);
        try t.expectEqual(10, buf4.data.len);

        pool.release(buf2);
        pool.release(buf3);
        pool.release(buf4);
    }
}
