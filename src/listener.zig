const std = @import("std");
const t = @import("t.zig");
const builtin = @import("builtin");
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

pub fn listen(comptime S: type, httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: Config) !void {
	var reqResPool = try initReqResPool(httpz_allocator, app_allocator, &config);
	defer reqResPool.deinit();

	var socket = net.StreamServer.init(.{
		.reuse_address = true,
		.kernel_backlog = 1024,
	});
	defer socket.deinit();

	var thread_pool: std.Thread.Pool = undefined;
	if (config.thread_pool > 0) {
		try std.Thread.Pool.init(&thread_pool, .{ .allocator = app_allocator, .n_jobs = config.thread_pool });
	}

	var no_delay = true;
	const address = blk: {
		if (config.unix_path) |unix_path| {
			no_delay = false;
			std.fs.deleteFileAbsolute(unix_path) catch {};
			break :blk try net.Address.initUnix(unix_path);
		} else {
			const listen_port = config.port.?;
			const listen_address = config.address.?;
			break :blk try net.Address.parseIp(listen_address, listen_port);
		}
	};
	try socket.listen(address);

	if (no_delay) {
		// TODO: Broken on darwin:
		// https://github.com/ziglang/zig/issues/17260
		// if (@hasDecl(os.TCP, "NODELAY")) {
		// 	try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
		// }
		try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
	}

	while (true) {
		if (socket.accept()) |conn| {
			const c: Conn = if (comptime builtin.is_test) undefined else conn;
			const args = .{ S, server, c, &reqResPool };
			if (comptime std.io.is_async) {
				try Loop.instance.?.runDetached(httpz_allocator, handleConnection, args);
			} else {
				if (config.thread_pool > 0) {
					try thread_pool.spawn(handleConnection, args);
				} else {
					const thrd = try std.Thread.spawn(.{}, handleConnection, args);
					thrd.detach();
				}
			}
		} else |err| {
			std.log.err("http.zig: failed to accept connection {}", .{err});
		}
	}
}

pub fn initReqResPool(httpz_allocator: Allocator, app_allocator: Allocator, config: *const Config) !ReqResPool {
	return try ReqResPool.init(httpz_allocator, config.pool, initReqRes, .{
		.config = config,
		.app_allocator = app_allocator,
		.httpz_allocator = httpz_allocator,
	});
}

pub fn handleConnection(comptime S: type, server: S, conn: Conn, reqResPool: *ReqResPool) void {
	std.os.maybeIgnoreSigpipe();

	const stream = if (comptime builtin.is_test) conn else conn.stream;
	defer stream.close();

	const reqResPair = reqResPool.acquire() catch |err| {
		stream.writeAll("HTTP/1.1 503\r\nRetry-After: 10\r\nContent-Length: 36\r\n\r\nServer overloaded. Please try again.") catch {};
		std.log.err("http.zig: failed to acquire request and response object from the pool {}", .{err});
		return;
	};
	defer reqResPool.release(reqResPair);

	const req = reqResPair.request;
	const res = reqResPair.response;
	var arena = reqResPair.arena;

	res.stream = stream;
	req.stream = stream;
	req.address = conn.address;

	while (true) {
		req.reset();
		res.reset();
		defer _ = arena.reset(.free_all);

		if (req.parse()) {
			if (!server.handle(req, res)) {
				return;
			}
		} else |err| {
			// hard to keep this request alive on a parseError since in a lot of
			// failure cases, it's unclear where 1 request stops and another starts.
			requestParseError(err, res);
			return;
		}
		req.drain() catch {
			return;
		};
	}
}

fn requestParseError(err: anyerror, res: *httpz.Response) void {
	switch (err) {
		error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
			res.status = 400;
			res.body = "Invalid Request";
			res.write() catch {};
		},
		error.HeaderTooBig => {
			res.status = 431;
			res.body = "Request header is too big";
			res.write() catch {};
		},
		else => {},
	}
}

// We pair together requests and responses, not because they're tightly coupled,
// but so that we have a 1 pool instead of 2, and thus have half the locking.
// Also, both the request and response can require dynamic memory allocation.
// Grouping them this way means we can create 1 arena per pair.
const RequestResponsePair = struct {
	allocator: Allocator,
	request: *httpz.Request,
	response: *httpz.Response,
	arena: *std.heap.ArenaAllocator,

	const Self = @This();

	pub fn deinit(self: *Self, httpz_allocator: Allocator) void {
		self.request.deinit(httpz_allocator);
		httpz_allocator.destroy(self.request);

		self.response.deinit(httpz_allocator);
		httpz_allocator.destroy(self.response);
		self.arena.deinit();
		httpz_allocator.destroy(self.arena);
		httpz_allocator.destroy(self);
	}
};

const RequestResponsePairConfig = struct {
	config: *const Config,
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

	const pair = try httpz_allocator.create(RequestResponsePair);
	pair.* = .{
		.arena = arena,
		.request = req,
		.response = res,
		.allocator = app_allocator,
	};

	return pair;
}

// All of this logic is largely tested in httpz.zig
