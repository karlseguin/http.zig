const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
const httpz = @import("httpz.zig");
const request = @import("request.zig");
const response = @import("response.zig");

const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;

const Loop = std.event.Loop;
const Allocator = std.mem.Allocator;
const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;

const os = std.os;
const net = std.net;
const assert = std.debug.assert;

pub fn Server(comptime H: type) type {
	return struct {
		const ReqPool = Pool(*request.Request, request.Config);
		const ResPool = Pool(*response.Response, response.Config);

		handler: H,
		config: Config,
		reqPool: ReqPool,
		resPool: ResPool,
		allocator: Allocator,
		socket: net.StreamServer,

		const Self = @This();

		pub fn init(allocator: Allocator, handler: H, config: Config) !Self {
			return .{
				.config = config,
				.handler = handler,
				.socket = undefined,
				.allocator = allocator,
				.reqPool = try ReqPool.init(allocator, config.request.pool_size, request.init, config.request),
				.resPool = try ResPool.init(allocator, config.response.pool_size, response.init, config.response),
			};
		}

		pub fn deinit(self: *Self) void {
			self.reqPool.deinit();
			self.resPool.deinit();
			self.handler.deinit();
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

			// TODO: I believe this should work, but it currently doesn't on 0.11-dev. Instead I have to
			// hardcode 1 for the setsocopt NODELAY option
			// if (@hasDecl(os.TCP, "NODELAY")) {
			// 	try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
			// }
			try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));

			std.log.info("listening on http://{}", .{socket.listen_address});

			while (true) {
				if (socket.accept()) |conn| {
					const stream: Stream = if (comptime builtin.is_test) undefined else conn.stream;
					if (comptime std.io.is_async) {
						const args = .{ stream };
						try Loop.instance.?.runDetached(allocator, self.handleConnection, args);
					} else {
						const args = .{ self, stream };
						const thrd = try std.Thread.spawn(.{}, handleConnection, args);
						thrd.detach();
					}
				} else |err| {
					std.log.err("failed to accept connection {}", .{err});
				}
			}
		}

		pub fn handleConnection(self: *Self, stream: Stream) void {
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

			const handler = self.handler;
			while (true) {
				req.reset();
				res.reset();
				if (req.parse(stream)) {
					if (!handler.handle(stream, req, res)) {
						return;
					}
				} else |err| {
					// hard to keep this request alive on a parseError since in a lot of
					// failure cases, it's unclear where 1 request stops and another starts.
					handler.requestParseError(stream, err, res);
					return;
				}

				req.drain() catch { return; };
			}
		}
	};
}

pub const Handler = struct {
	router: *httpz.Router,
	errorHandler: httpz.ActionError,

	const Self = @This();

	pub fn deinit(self: Self) void {
		self.router.deinit();
	}

	pub fn handle(self: Self, stream: Stream, req: *request.Request, res: *response.Response) bool {
		const router = self.router;
		const action = router.route(req.method, req.url.path, &req.params);
		action(req, res) catch |err| switch (err) {
			error.BodyTooBig => {
				res.status = 431;
				res.setBody("Request body is too big");
				res.write(stream) catch {};
			},
			else => self.errorHandler(err, req, res)
		};

		res.write(stream) catch {
			return false;
		};

		return req.canKeepAlive();
	}

	pub fn requestParseError(_: Self, stream: Stream, err: anyerror, res: *httpz.Response) void {
		switch (err) {
			error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
				res.status = 400;
				res.setBody("Invalid Request");
				res.write(stream) catch {};
			},
			error.HeaderTooBig => {
				res.status = 431;
				res.setBody("Request header is too big");
				res.write(stream) catch {};
			},
			else => {},
		}
	}
};

pub fn errorHandler(err: anyerror, req: *httpz.Request, res: *httpz.Response) void {
	res.status = 500;
	res.setBody("Internal Server Error");
	std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{req.url.raw, err});
}

pub fn notFound(_: *httpz.Request, res: *httpz.Response) !void {
	res.status = 404;
	res.setBody("Not Found");
}

// All of this logic is largely tested in httpz.zig
