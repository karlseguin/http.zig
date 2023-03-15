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
				.reqPool = try ReqPool.init(allocator, 100, request.init, config.request),
				.resPool = try ResPool.init(allocator, 100, response.init, config.response),
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
			std.log.info("listening on http://{}", .{socket.listen_address});

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

		pub fn handleConnection(self: *Self, comptime S: type, stream: S) void {
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
				if (req.parse(S, stream)) {
					if (!handler.handle(S, stream, req, res)) {
						return;
					}
				} else |err| {
					// hard to keep this request alive on a parseError since in a lot of
					// failure cases, it's unclear where 1 request stops and another starts.
					handler.requestParseError(S, stream, err, res);
					return;
				}
				req.reset();
				res.reset();
			}
		}
	};
}

pub const Handler = struct {
	router: *httpz.Router,

	const Self = @This();

	pub fn deinit(self: Self) void {
		self.router.deinit();
	}

	pub fn handle(self: Self, comptime S: type, stream: S, req: *request.Request, res: *response.Response) bool {
		if (self.router.route(req.method, req.url.path, &req.params)) |action| {
			action(req, res) catch |err| {
				self.unhandledError(err, req, res);
			};
		} else {
			self.noRouteFound(res);
		}

		res.write(S, stream) catch {
			return false;
		};

		return req.canKeepAlive();
	}

	pub fn requestParseError(_: Self, comptime S: type, stream: S, err: anyerror, res: *httpz.Response) void {
		switch (err) {
			error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
				res.status = 400;
				res.text("Invalid Request");
				res.write(S, stream) catch {};
			},
			else => {},
		}
	}

	pub fn unhandledError(_: Self, err: anyerror, req: *httpz.Request, res: *httpz.Response) void {
		res.status = 500;
		res.text("Internal Server Error");
		std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{req.url.raw, err});
	}

	pub fn noRouteFound(_: Self, res: *httpz.Response) void {
		res.status = 404;
		res.text("Not Found");
	}
};

// this is largely tested in httpz.zig
