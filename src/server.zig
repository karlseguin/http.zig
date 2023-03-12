const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
const httpz = @import("httpz.zig");
const request = @import("request.zig");
const response = @import("response.zig");

const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;
const Stream = @import("stream.zig").Stream;

const Loop = std.event.Loop;
const Allocator = std.mem.Allocator;

const net = std.net;
const assert = std.debug.assert;

pub const Server = struct {
	const ReqPool = Pool(*request.Request, request.Config);
	const ResPool = Pool(*response.Response, response.Config);

	config: Config,
	reqPool: ReqPool,
	resPool: ResPool,
	allocator: Allocator,
	socket: net.StreamServer,

	const Self = @This();

	pub fn start(allocator: Allocator, config: Config) !Server {
		// the static portion of our request buffer must be at least
		// as big as the maximum possible header we'll accept.
		assert(config.request.buffer_size >= config.request.max_header_size);
		return .{
			.config = config,
			.socket = undefined,
			.allocator = allocator,
			.reqPool = try ReqPool.init(allocator, 100, request.init, config.request),
			.resPool = try ResPool.init(allocator, 100, response.init, config.response),
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

		const listen_address = config.address orelse "127.0.0.1";
		const listen_port = config.port orelse 5882;
		try socket.listen(net.Address.parseIp(listen_address, listen_port) catch unreachable);
		std.log.info("listening at {}", .{socket.listen_address});

		while (true) {
			if (socket.accept()) |conn| {
				const stream = Stream{ .stream = conn.stream };
				if (comptime std.io.is_async) {
					const args = .{ Stream, stream };
					try Loop.instance.?.runDetached(allocator, self.handleConnection, args);
				} else {
					const args = .{ self, Stream, stream };
					const thrd = try std.Thread.spawn(.{}, handleConnection, args);
					thrd.detach();
				}
			} else |err| {
				std.log.err("failed to accept connection {}", .{err});
			}
		}
	}

	fn handleConnection(self: *Self, comptime S: type, stream: S) void {
		defer stream.close();

		var reqPool = self.reqPool;
		var req = reqPool.acquire() catch |err| {
			std.log.err("failed to acquire request object from the pool {}", .{err});
			return;
		};
		defer reqPool.release(req);

		var resPool = self.resPool;
		var res = resPool.acquire() catch |err| {
			std.log.err("failed to acquire response object from the pool {}", .{err});
			return;
		};
		defer resPool.release(res);

		while (true) {
			req.parse(S, stream) catch |err| switch (err) {
				error.UnknownMethod, error.InvalidRequestTarget,
				error.UnknownProtocol, error.UnsupportedProtocol,
				error.InvalidHeaderLine => {
					requestParseInvalidError(S, stream, res);
					return;
				},
				error.ConnectionClosed => return,
				else => {
					requestParseUnhandledError(S, stream, res);
					return;
				},
			};

			res.status = 200;
			res.write(S, stream) catch {
				return;
			};


			if (!req.canKeepAlive()) {
				return;
			}
			req.reset();
			res.reset();
		}
	}
};

pub fn requestParseInvalidError(comptime S: type, stream: S, res: *httpz.Response) void {
	res.write(S, stream) catch {};
}

pub fn requestParseUnhandledError(comptime S: type, stream: S, res: *httpz.Response) void {
	res.write(S, stream) catch {};
}


test "server" {
	var s = try Server.start(t.allocator, .{});
	defer s.deinit();
}
