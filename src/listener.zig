const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
const httpz = @import("httpz.zig");

const Pool = @import("pool.zig").Pool;
const Config = @import("config.zig").Config;

const Loop = std.event.Loop;
const Allocator = std.mem.Allocator;
const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;
const Conn = if (builtin.is_test) *t.Stream else std.net.StreamServer.Connection;

const os = std.os;
const net = std.net;

const ReqResPool = Pool(*RequestResponsePair, RequestResponsePairConfig);

pub fn listen(comptime H: type, httpz_allocator: Allocator, app_allocator: Allocator, handler: H, config: Config) !void {
	var reqResPool = try initReqResPool(httpz_allocator, app_allocator, config);
	var socket = net.StreamServer.init(.{
		.reuse_address = true,
		.kernel_backlog = 1024,
	});
	defer socket.deinit();

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
			const args = .{H, handler, c, &reqResPool};
			if (comptime std.io.is_async) {
				try Loop.instance.?.runDetached(httpz_allocator, handleConnection, args);
			} else {
				const thrd = try std.Thread.spawn(.{}, handleConnection, args);
				thrd.detach();
			}
		} else |err| {
			std.log.err("failed to accept connection {}", .{err});
		}
	}
}

pub fn initReqResPool(httpz_allocator: Allocator, app_allocator: Allocator, config: Config) !ReqResPool {
	return try ReqResPool.init(httpz_allocator, config.pool_size, initReqRes, .{
		.config = config,
		.app_allocator = app_allocator,
		.httpz_allocator = httpz_allocator,
	});
}

pub fn handleConnection(comptime H: type, handler: H, conn: Conn, reqResPool: *ReqResPool) void {
	const stream = if (comptime builtin.is_test) conn else conn.stream;
	defer stream.close();

	const reqResPair = reqResPool.acquire() catch |err| {
		std.log.err("failed to acquire request and response object from the pool {}", .{err});
		return;
	};
	defer reqResPool.release(reqResPair);

	const req = reqResPair.request;
	const res = reqResPair.response;
	var arena = reqResPair.arena;

	req.stream = stream;
	defer _ = arena.reset(.free_all);

	while (true) {
		req.reset();
		res.reset();
		// TODO: this does not work, if you keep trying to use the arena allocator
		// after this, you'll get a segfault. It can take multiple hits before it
		// happens, but it will happen.
		// defer _ = arena.reset(.{.retain_with_limit = 8192});

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

pub fn Handler(comptime C: type) type {
	return struct {
		ctx: C,
		router: httpz.Router(C),
		errorHandler: httpz.ErrorHandlerAction(C),

		const Self = @This();

		pub fn deinit(self: Self) void {
			var r = self.router;
			r.deinit();
		}

		pub fn handle(self: Self, stream: Stream, req: *httpz.Request, res: *httpz.Response) bool {
			const router = self.router;
			const action = router.route(req.method, req.url.path, &req.params);
			dispatch(action, req, res, self.ctx) catch |err| switch (err) {
				error.BodyTooBig => {
					res.status = 431;
					res.body = "Request body is too big";
					res.write(stream) catch return false;
				},
				else => {
					if (comptime C == void) {
						self.errorHandler(req, res, err);
					} else {
						self.errorHandler(req, res, err, self.ctx);
					}
				}
			};
			res.write(stream) catch return false;
			return req.canKeepAlive();
		}

		pub fn dispatch(action: httpz.Action(C), req: *httpz.Request, res: *httpz.Response, ctx: C) !void {
			if (comptime C == void) {
				try action(req, res);
			} else {
				try action(req, res, ctx);
			}
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
}

// We pair together requests and responses, not because they're tightly coupled,
// but so that we have a 1 pool instead of 2, and thus have half the locking.
// Also, both the request and response can require dynamic memory allocation.
// Grouping them this way means we can create 1 arena per pair.
const RequestResponsePair = struct{
	allocator: Allocator,
	request: *httpz.Request,
	response: *httpz.Response,
	arena: *std.heap.ArenaAllocator,

	const Self = @This();

	pub fn deinit(self: *Self, allocator: Allocator) void {
		self.request.deinit(allocator);
		allocator.destroy(self.request);

		self.response.deinit(allocator);
		allocator.destroy(self.response);
		self.arena.deinit();
	}
};

const RequestResponsePairConfig = struct {
	config: Config,
	app_allocator: Allocator,
	httpz_allocator: Allocator,
};

// Should not be called directly, but initialized through a pool
pub fn initReqRes(c: RequestResponsePairConfig) !*RequestResponsePair {
	const httpz_allocator = c.httpz_allocator;

	var arena = try httpz_allocator.create(std.heap.ArenaAllocator);
	arena.* = std.heap.ArenaAllocator.init(c.app_allocator);
	const app_allocator = arena.allocator();

	var req = try httpz_allocator.create(httpz.Request);
	try req.init(httpz_allocator, app_allocator, c.config.request);

	var res = try httpz_allocator.create(httpz.Response);
	try res.init(httpz_allocator, app_allocator, c.config.response);

	var pair = try httpz_allocator.create(RequestResponsePair);
	pair.* = .{
		.arena = arena,
		.request = req,
		.response = res,
		.allocator = app_allocator,
	};

	return pair;
}

// All of this logic is largely tested in httpz.zig
