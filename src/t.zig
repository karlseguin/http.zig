// Internal helpers used by this library
// If you're looking for helpers to help you mock/test
// httpz.Request and httpz.Response, checkout testing.zig
// which is exposed as httpz.testing.
const std = @import("std");

const mem = std.mem;
const ArrayList = std.ArrayList;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub fn expectEqual(expected: anytype, actual: anytype) !void {
	try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub var aa = std.heap.ArenaAllocator.init(allocator);
pub const arena = aa.allocator();

pub fn getRandom() std.rand.DefaultPrng {
	var seed: u64 = undefined;
	std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
	return std.rand.DefaultPrng.init(seed);
}

const dummy_address = std.net.Address.initIp4([_]u8{127, 0, 0, 200}, 0);

// mock for std.net.StreamServer.Connection
pub const Connection = struct {
	stream: Stream,
	address: std.net.Address = dummy_address,
};

pub const Stream = struct {
	state: *State = undefined,
	handle: c_int = 0,

	const State = struct {
		closed: bool,
		read_index: usize,
		to_read: ArrayList(u8),
		random: ?std.rand.DefaultPrng,
		received: ArrayList(u8),
	};

	pub fn init() Stream {
		return initWithAllocator(allocator);
	}

	pub fn initWithAllocator(a: std.mem.Allocator) Stream {
		const state = a.create(State) catch unreachable;
		state.* = .{
			.closed = false,
			.read_index = 0,
			.random = getRandom(),
			.to_read = ArrayList(u8).init(a),
			.received = ArrayList(u8).init(a),
		};

		return .{
			.handle = 0,
			.state = state,
		};
	}

	pub fn deinit(self: Stream) void {
		self.state.to_read.deinit();
		self.state.received.deinit();
		allocator.destroy(self.state);
	}

	// mock for std.net.StreamServer.Connection
	pub fn wrap(self: Stream) Connection {
		return .{.stream = self};
	}

	pub fn reset(self: Stream) void {
		self.state.to_read.clearRetainingCapacity();
		self.state.received.clearRetainingCapacity();
	}

	pub fn add(self: Stream, value: []const u8) Stream {
		self.state.to_read.appendSlice(value) catch unreachable;
		return self;
	}

	pub fn read(self: Stream, buf: []u8) !usize {
		var state = self.state;
		std.debug.assert(!state.closed);

		const read_index = state.read_index;
		const items = state.to_read.items;

		if (read_index == items.len) {
			return 0;
		}
		if (buf.len == 0) {
			return 0;
		}

		// let's fragment this message
		const left_to_read = items.len - read_index;
		const max_can_read = if (buf.len < left_to_read) buf.len else left_to_read;

		var to_read = max_can_read;
		if (state.random) |*r| {
			const random = r.random();
			to_read = random.uintAtMost(usize, max_can_read - 1) + 1;
		}

		var data = items[read_index..(read_index+to_read)];
		if (data.len > buf.len) {
			// we have more data than we have space in buf (our target)
			// we'll give it when it can take
			data = data[0..buf.len];
		}
		state.read_index = read_index + data.len;

		// std.debug.print("TEST: {d} {d} {d}\n", .{data.len, read_index, max_can_read});
		for (data, 0..) |b, i| {
			buf[i] = b;
		}

		return data.len;
	}

	// store messages that are written to the stream
	pub fn writeAll(self: Stream, data: []const u8) !void {
		self.state.received.appendSlice(data) catch unreachable;
	}

	pub fn close(self: Stream) void {
		self.state.closed = true;
	}

	pub fn received(self: Stream) []u8 {
		return self.state.received.items;
	}
};

pub fn randomString(random: std.rand.Random, a: std.mem.Allocator, max: usize) []u8 {
	var buf = a.alloc(u8, random.uintAtMost(usize, max) + 1) catch unreachable;
	const valid = "abcdefghijklmnopqrstuvwxyz0123456789-_/";
	for (0..buf.len) |i| {
		buf[i] = valid[random.uintAtMost(usize, valid.len-1)];
	}
	return buf;
}
