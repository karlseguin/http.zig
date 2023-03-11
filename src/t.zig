const std = @import("std");

const mem = std.mem;
const ArrayList = std.ArrayList;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

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
	received: ArrayList([]const u8),

	pub fn init() Stream {
		return .{
			.closed = false,
			.read_index = 0,
			.random = getRandom(),
			.to_read = ArrayList(u8).init(allocator),
			.received = ArrayList([]const u8).init(allocator),
		};
	}

	pub fn add(self: *Stream, value: []const u8) *Stream {
		self.to_read.appendSlice(value) catch unreachable;
		return self;
	}

	pub fn read(self: *Stream, buf: []u8) !usize {
		std.debug.assert(!self.closed);

		const read_index = self.read_index;
		const items = self.to_read.items;
		if (read_index == items.len) {
			return 0;
		}

		// let's fragment this message
		const left_to_read = items.len - read_index;
		const max_can_read = if (buf.len < left_to_read) buf.len else left_to_read;

		const random = self.random.random();
		const to_read = random.uintAtMost(usize, max_can_read - 1) + 1;

		var data = items[read_index..(read_index+to_read)];
		if (data.len > buf.len) {
			// we have more data than we have space in buf (our target)
			// we'll give it when it can take
			data = data[0..buf.len];
		}
		self.read_index = read_index + data.len;

		for (data, 0..) |b, i| {
			buf[i] = b;
		}

		return data.len;
	}

	// store messages that are written to the stream
	pub fn write(self: *Stream, data: []const u8) !void {
		std.debug.assert(!self.closed);
		var copy = allocator.alloc(u8, data.len) catch unreachable;
		mem.copy(u8, copy, data);
		self.received.append(copy) catch unreachable;
	}

	pub fn close(self: *Stream) void {
		self.closed = true;
	}

	pub fn deinit(self: *Stream) void {
		self.to_read.deinit();

		if (self.received.items.len > 0) {
			for (self.received.items) |buf| {
				allocator.free(buf);
			}
			self.received.deinit();
		}

		self.* = undefined;
	}
};
