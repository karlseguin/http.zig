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
	buf_index: usize,
	read_index: usize,
	to_read: ArrayList([]const u8),
	random: std.rand.DefaultPrng,
	received: ArrayList([]const u8),

	pub fn init() Stream {
		return .{
			.closed = false,
			.buf_index = 0,
			.read_index = 0,
			.random = getRandom(),
			.to_read = ArrayList([]const u8).init(allocator),
			.received = ArrayList([]const u8).init(allocator),
		};
	}

	pub fn add(self: *Stream, value: []const u8) *Stream {
		// Take ownership of this data so that we can consistently free each
		// (necessary because we need to allocate data for frames)
		var copy = allocator.alloc(u8, value.len) catch unreachable;
		mem.copy(u8, copy, value);
		self.to_read.append(copy) catch unreachable;
		return self;
	}

	pub fn read(self: *Stream, buf: []u8) !usize {
		std.debug.assert(!self.closed);

		const items = self.to_read.items;
		if (self.read_index == items.len) {
			return 0;
		}

		var data = items[self.read_index][self.buf_index..];
		if (data.len > buf.len) {
			// we have more data than we have space in buf (our target)
			// we'll fill the target buffer, and keep track of where
			// we our in our source buffer, so that that on the next read
			// we'll use the same source buffer, but at the offset
			self.buf_index += buf.len;
			data = data[0..buf.len];
		} else {
			// ok, fully read this one, next time we can move on
			self.buf_index = 0;
			self.read_index += 1;
		}

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
		for (self.to_read.items) |buf| {
			allocator.free(buf);
		}
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
