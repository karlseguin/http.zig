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

// // mock for std.net.StreamServer.Connection
// pub const Connection = struct {
// 	stream: Stream,
// 	address: std.net.Address = dummy_address,
// };

pub const Stream = struct {
	// the stream that the server gets
	stream: std.net.Stream,

	// the client (e.g. browser stream)
	client: std.net.Stream,

	closed: bool = false,

	conn: std.net.StreamServer.Connection,

	pub fn init() Stream {
		var pair: [2]c_int = undefined;
		const rc = std.c.socketpair(std.os.AF.LOCAL, std.os.SOCK.STREAM, 0, &pair);
		if (rc != 0) {
			@panic("socketpair fail");
		}

		const timeout = std.mem.toBytes(std.os.timeval{
			.tv_sec = 0,
			.tv_usec = 20_000,
		});
		std.os.setsockopt(pair[0], std.os.SOL.SOCKET, std.os.SO.RCVTIMEO, &timeout) catch unreachable;
		std.os.setsockopt(pair[0], std.os.SOL.SOCKET, std.os.SO.SNDTIMEO, &timeout) catch unreachable;
		std.os.setsockopt(pair[1], std.os.SOL.SOCKET, std.os.SO.RCVTIMEO, &timeout) catch unreachable;
		std.os.setsockopt(pair[1], std.os.SOL.SOCKET, std.os.SO.SNDTIMEO, &timeout) catch unreachable;

		std.os.setsockopt(pair[1], std.os.SOL.SOCKET, std.os.SO.SNDBUF, &mem.toBytes(@as(c_int, 10_000))) catch unreachable;

		const server = std.net.Stream{.handle = pair[0]};
		return .{
			.stream = server,
			.conn = .{.stream = server, .address = dummy_address},
			.client = std.net.Stream{.handle = pair[1]},
		};
	}

	pub fn deinit(self: *Stream) void {
		if (self.closed == false) {
			self.closed = true;
			self.stream.close();
		}
		self.client.close();
	}

	// force the server side socket to be closed, which helps our reading-test
	// know that there's no more data.
	pub fn close(self: *Stream) void {
		if (self.closed == false) {
			self.closed = true;
			self.stream.close();
		}
	}

	pub fn write(self: Stream, data: []const u8) void {
		self.client.writeAll(data) catch unreachable;
	}

	pub fn read(self: Stream, a: std.mem.Allocator) !ArrayList(u8) {
		var buf: [1024]u8 = undefined;
		var arr = std.ArrayList(u8).init(a);

		while (true) {
			const n = self.client.read(&buf) catch |err| switch (err) {
				error.WouldBlock => return arr,
				else => return err,
			};
			if (n == 0) return arr;
			try arr.appendSlice(buf[0..n]);
		}
		unreachable;
	}

	pub fn expect(self: Stream, expected: []const u8) !void {
		var pos: usize = 0;
		var buf = try allocator.alloc(u8, expected.len);
		defer allocator.free(buf);
		while (pos < buf.len) {
			const n = try self.client.read(buf[pos..]);
			if (n == 0) break;
			pos += n;
		}
		try expectString(expected, buf);
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
