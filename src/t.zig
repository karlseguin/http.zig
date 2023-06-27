// Internal helpers used by this library
// If you're looking for helpers to help you mock/test
// httpz.Request and httpz.Response, checkout testing.zig
// which is exposed as httpz.testing.
const std = @import("std");

const mem = std.mem;
const ArrayList = std.ArrayList;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub var aa = std.heap.ArenaAllocator.init(allocator);
pub const arena = aa.allocator();

pub fn reset() void {
    _ = aa.reset(.free_all);
}

pub fn getRandom() std.rand.DefaultPrng {
    var seed: u64 = undefined;
    std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    return std.rand.DefaultPrng.init(seed);
}

pub const Stream = struct {
    closed: bool,
    read_index: usize,
    to_read: ArrayList(u8),
    random: std.rand.DefaultPrng,
    received: ArrayList(u8),

    const Self = @This();

    pub fn init() *Stream {
        return initWithAllocator(allocator);
    }

    pub fn initWithAllocator(a: std.mem.Allocator) *Stream {
        var s = a.create(Stream) catch unreachable;
        s.closed = false;
        s.read_index = 0;
        s.random = getRandom();
        s.to_read = ArrayList(u8).init(a);
        s.received = ArrayList(u8).init(a);
        return s;
    }

    pub fn deinit(self: *Self) void {
        self.to_read.deinit();
        self.received.deinit();
        allocator.destroy(self);
    }

    pub fn reset(self: *Self) void {
        self.to_read.clearRetainingCapacity();
        self.received.clearRetainingCapacity();
    }

    pub fn add(self: *Self, value: []const u8) *Self {
        self.to_read.appendSlice(value) catch unreachable;
        return self;
    }

    pub fn read(self: *Self, buf: []u8) !usize {
        std.debug.assert(!self.closed);

        const read_index = self.read_index;
        const items = self.to_read.items;

        if (read_index == items.len) {
            return 0;
        }
        if (buf.len == 0) {
            return 0;
        }

        // let's fragment this message
        const left_to_read = items.len - read_index;
        const max_can_read = if (buf.len < left_to_read) buf.len else left_to_read;

        const random = self.random.random();
        const to_read = random.uintAtMost(usize, max_can_read - 1) + 1;

        var data = items[read_index..(read_index + to_read)];
        if (data.len > buf.len) {
            // we have more data than we have space in buf (our target)
            // we'll give it when it can take
            data = data[0..buf.len];
        }
        self.read_index = read_index + data.len;

        // std.debug.print("TEST: {d} {d} {d}\n", .{data.len, read_index, max_can_read});
        for (data, 0..) |b, i| {
            buf[i] = b;
        }

        return data.len;
    }

    // store messages that are written to the stream
    pub fn writeAll(self: *Self, data: []const u8) !void {
        self.received.appendSlice(data) catch unreachable;
    }

    pub fn close(self: *Self) void {
        self.closed = true;
    }
};

pub fn randomString(random: std.rand.Random, a: std.mem.Allocator, max: usize) []u8 {
    var buf = a.alloc(u8, random.uintAtMost(usize, max) + 1) catch unreachable;
    const valid = "abcdefghijklmnopqrstuvwxyz0123456789-_/";
    for (0..buf.len) |i| {
        buf[i] = valid[random.uintAtMost(usize, valid.len - 1)];
    }
    return buf;
}
