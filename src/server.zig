const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
const request = @import("request.zig");

const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;

const Loop = std.event.Loop;
const Allocator = std.mem.Allocator;

const net = std.net;
const assert = std.debug.assert;

pub const Server = struct {
	const ReqPool = Pool(*request.Request, request.Config);

	config: Config,
	reqPool: ReqPool,
	allocator: Allocator,
	socket: net.StreamServer,

	const Self = @This();

	pub fn init(allocator: Allocator, config: Config) !Server {
		// the static portion of our request buffer must be at least
		// as big as the maximum possible header we'll accept.
		assert(config.request.buffer_size >= config.request.max_header_size);
		return .{
			.config = config,
			.socket = undefined,
			.allocator = allocator,
			.reqPool = try ReqPool.init(allocator, 100, request.init, config.request),
		};
	}

	pub fn deinit(self: *Self) void {
		self.reqPool.deinit();
	}

	pub fn listen(self: *Self) !void {
		const config = self.config;
		const allocator = self.allocator;

		var socket = net.StreamServer.init(.{ .reuse_address = true });
		defer socket.deinit();
		self.socket = socket;

		try socket.listen(net.Address.parseIp(config.address, config.port) catch unreachable);
		std.log.info("listening at {}", .{socket.listen_address});

		while (true) {
			if (socket.accept()) |conn| {
				const stream = Stream{ .stream = conn.stream };
				const args = .{ stream.Net, stream };
				try Loop.instance.?.runDetached(allocator, self.handleConnection, args);
			} else |err| {
				std.log.err("failed to accept connection {}", .{err});
			}
		}
	}

	fn handleConnection(self: *Self, comptime S: type, stream: S) void {
		defer stream.close();

		var req = self.reqPool.acquire() catch |err| {
			std.log.err("failed to acquire request object from the pool {}", .{err});
			return;
		};
		defer self.reqPool.release(req);

		while (true) {
			req.parse(S, stream);
		}
	}
};

// fn handeRequest(comptime S: type, stream: S, request: request.Request) !bool {
// 	// var request: request.Request;
// 	// return parseRequest(S, stream, &request, reqBuffer)
// 	return false;
// }

// fn parseRequest(comptime S: type, stream: S, request: *Request, reqBuffer: buffer.Buffer) !bool {
// 	@setRuntimeSafety(builtin.is_test);

// 	var bufferRead = 0;
// 	var headerDone = false;
// 	var headerUnparsed = 0;

// 	// header always fits inside the static portion of our buffer
// 	const headerBuffer = reqBuffer.static;

// 	while (!headerDone) {
// 		const n = reqBuffer.read(stream);
// 		if (n == 0) {
// 			return false;
// 		}
// 		bufferRead += n;

// 		while (true) {
// 			const data = headerBuffer[headerUnparsed..bufferRead];
// 			const index = mem.indexOfScalar(u8, data, '\r') orelse unreachable;
// 			if (index == 0) {
// 				break;
// 			}
// 			const headerLine = data[headerUnparsed..index];
// 			headerUnparsed += index + 2;
// 		}
// 	}

// 	return true;
// }

// wraps a real stream so that we can mock it during tests
pub const Stream = struct {
	stream: std.net.Stream,

	const Self = @This();

	pub fn read(self: Self, data: []u8) !usize {
		return self.stream.read(data);
	}

	pub fn close(self: Self) void {
		return self.stream.close();
	}

	// Taken from io/Writer.zig (for writeAll) which calls the net.zig's Stream.write
	// function in this loop
	pub fn write(self: Self, data: []const u8) !void {
		var index: usize = 0;
		const el = std.event.Loop.instance.?;
		const h = self.stream.handle;
		while (index != data.len) {
			index += try el.write(h, data[index..], false);
		}
	}
};


test "server" {
	var s = try Server.init(t.allocator, .{});
	defer s.deinit();
}
