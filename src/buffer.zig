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

// When we're in blocking mode, the Pool is shared by threads in the blocking
// worker's threadpool. Thus, we need to synchornize access.
// When we're not in blocking mode, every worker gets its own Pool and the pool
// is only accessed from that worker thread, so no lockig is required.
pub const Pool = struct {
    const M = if (blockingMode()) Mutex else void;

    io: Io,
    mutex: M,
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
            .mutex = if (comptime blockingMode()) .init else {},
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

    fn allocType(self: *Pool, allocator: Allocator, buffer_type: Buffer.Type, size: usize) !Buffer {
        if (size > self.buffer_size) {
            metrics.allocBufferLarge(size);
            return .{
                .type = buffer_type,
                .data = try allocator.alloc(u8, size),
            };
        }

        self.lock();
        const available = self.available;
        if (available == 0) {
            self.unlock();
            metrics.allocBufferEmpty(size);
            return .{
                .type = buffer_type,
                .data = try allocator.alloc(u8, size),
            };
        }
        defer self.unlock();

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
                self.lock();
                defer self.unlock();
                const available = self.available;
                self.buffers[available] = buffer;
                self.available = available + 1;
            },
        }
    }

    inline fn lock(self: *Pool) void {
        if (comptime blockingMode()) {
            self.mutex.lockUncancelable(self.io);
        }
    }
    inline fn unlock(self: *Pool) void {
        if (comptime blockingMode()) {
            self.mutex.unlock(self.io);
        }
    }
};

const t = @import("t.zig");
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
