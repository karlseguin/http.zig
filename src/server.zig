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
const Conn = if (builtin.is_test) *t.Stream else std.net.StreamServer.Connection;

const os = std.os;
const net = std.net;
const assert = std.debug.assert;

pub fn Server(comptime H: type) type {
	return struct {
		const ReqResPool = Pool(*RequestResponsePair, Config);

		handler: H,
		config: Config,
		allocator: Allocator,
		reqResPool: ReqResPool,
		socket: net.StreamServer,

		const Self = @This();

		pub fn init(allocator: Allocator, handler: H, config: Config) !Self {
			return .{
				.config = config,
				.handler = handler,
				.socket = undefined,
				.allocator = allocator,
				.reqResPool = try ReqResPool.init(allocator, config.pool_size, reqResInit, config),
			};
		}

		pub fn deinit(self: *Self) void {
			self.reqResPool.deinit();
			self.handler.deinit();
		}

		pub fn listen(self: *Self) !void {
			const config = self.config;
			const allocator = self.allocator;

			var socket = net.StreamServer.init(.{
				.reuse_address = true,
				.kernel_backlog = 1024,
			});
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
					const c: Conn = if (comptime builtin.is_test) undefined else conn;
					if (comptime std.io.is_async) {
						const args = .{ c };
						try Loop.instance.?.runDetached(allocator, self.handleConnection, args);
					} else {
						const args = .{ self, c };
						const thrd = try std.Thread.spawn(.{}, handleConnection, args);
						thrd.detach();
					}
				} else |err| {
					std.log.err("failed to accept connection {}", .{err});
				}
			}
		}

		pub fn handleConnection(self: *Self, conn: Conn) void {
			const stream = if (comptime builtin.is_test) conn else conn.stream;
			defer stream.close();

			var reqResPool = &self.reqResPool;
			const reqResPair = reqResPool.acquire() catch |err| {
				std.log.err("failed to acquire request and response object from the pool {}", .{err});
				return;
			};
			defer reqResPool.release(reqResPair);

			const req = reqResPair.request;
			const res = reqResPair.response;
			var arena = reqResPair.arena;

			req.prepareForNewStream(stream);

			const handler = self.handler;
			while (true) {
				req.reset();
				res.reset();
				defer _ = arena.reset(.free_all);

				if (req.parse()) {
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
				res.body = "Request body is too big";
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
				res.body = "Invalid Request";
				res.write(stream) catch {};
			},
			error.HeaderTooBig => {
				res.status = 431;
				res.body = "Request header is too big";
				res.write(stream) catch {};
			},
			else => {},
		}
	}
};

pub fn errorHandler(err: anyerror, req: *httpz.Request, res: *httpz.Response) void {
	res.status = 500;
	res.body = "Internal Server Error";
	std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{req.url.raw, err});
}

pub fn notFound(_: *httpz.Request, res: *httpz.Response) !void {
	res.status = 404;
	res.body = "Not Found";
}

// We pair together requests and responses, not because they're tightly coupled,
// but so that we have a 1 pool instead of 2, and thus have half the locking.
// Also, both the request and response can require dynamic memory allocation.
// Grouping them this way means we can create 1 arena per pair.
const RequestResponsePair = struct{
	request: *httpz.Request,
	response: *httpz.Response,
	arena: std.heap.ArenaAllocator,
	allocator: Allocator,

	const Self = @This();

	pub fn deinit(self: *Self, allocator: Allocator) void {
		self.request.deinit(allocator);
		allocator.destroy(self.request);

		self.response.deinit(allocator);
		allocator.destroy(self.response);
		self.arena.deinit();
	}
};

// Should not be called directly, but initialized through a pool
pub fn reqResInit(allocator: Allocator, config: Config) !*RequestResponsePair {
	var pair = try allocator.create(RequestResponsePair);
	pair.arena = std.heap.ArenaAllocator.init(allocator);

	var aa = pair.arena.allocator();
	var req = try allocator.create(httpz.Request);
	try req.init(allocator, aa, config.request);

	var res = try allocator.create(httpz.Response);
	try res.init(allocator, aa, config.response);

	pair.request = req;
	pair.response = res;
	pair.allocator = aa;
	return pair;
}

// All of this logic is largely tested in httpz.zig
