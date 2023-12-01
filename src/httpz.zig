const std = @import("std");

const Thread = std.Thread;
pub const testing = @import("testing.zig");

pub const routing = @import("router.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");

pub const Router = routing.Router;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Url = @import("url.zig").Url;
pub const Config = @import("config.zig").Config;

const Allocator = std.mem.Allocator;
const Conn = @import("conn.zig").Conn;

pub const Protocol = enum {
	HTTP10,
	HTTP11,
};

pub const Method = enum {
	GET,
	HEAD,
	POST,
	PUT,
	PATCH,
	DELETE,
	OPTIONS,
};

pub const ContentType = enum {
	BINARY,
	CSS,
	CSV,
	EOT,
	EVENTS,
	GIF,
	GZ,
	HTML,
	ICO,
	JPG,
	JS,
	JSON,
	OTF,
	PDF,
	PNG,
	SVG,
	TAR,
	TEXT,
	TTF,
	WASM,
	WEBP,
	WOFF,
	WOFF2,
	XML,
	UNKNOWN,

	const JS_BIT = @as(u16, @bitCast([2]u8{'j', 's'}));
	const GZ_BIT = @as(u16, @bitCast([2]u8{'g', 'z'}));
	const CSS_BIT = @as(u24, @bitCast([3]u8{'c', 's', 's'}));
	const CSV_BIT = @as(u24, @bitCast([3]u8{'c', 's', 'v'}));
	const EOT_BIT = @as(u24, @bitCast([3]u8{'e', 'o', 't'}));
	const GIF_BIT = @as(u24, @bitCast([3]u8{'g', 'i', 'f'}));
	const HTM_BIT = @as(u24, @bitCast([3]u8{'h', 't', 'm'}));
	const ICO_BIT = @as(u24, @bitCast([3]u8{'i', 'c', 'o'}));
	const JPG_BIT = @as(u24, @bitCast([3]u8{'j', 'p', 'g'}));
	const OTF_BIT = @as(u24, @bitCast([3]u8{'o', 't', 'f'}));
	const PDF_BIT = @as(u24, @bitCast([3]u8{'p', 'd', 'f'}));
	const PNG_BIT = @as(u24, @bitCast([3]u8{'p', 'n', 'g'}));
	const SVG_BIT = @as(u24, @bitCast([3]u8{'s', 'v', 'g'}));
	const TAR_BIT = @as(u24, @bitCast([3]u8{'t', 'a', 'r'}));
	const TTF_BIT = @as(u24, @bitCast([3]u8{'t', 't', 'f'}));
	const XML_BIT = @as(u24, @bitCast([3]u8{'x', 'm', 'l'}));
	const JPEG_BIT = @as(u32, @bitCast([4]u8{'j','p','e','g'}));
	const JSON_BIT = @as(u32, @bitCast([4]u8{'j','s','o','n'}));
	const HTML_BIT = @as(u32, @bitCast([4]u8{'h','t','m','l'}));
	const TEXT_BIT = @as(u32, @bitCast([4]u8{'t','e','x','t'}));
	const WASM_BIT = @as(u32, @bitCast([4]u8{'w','a','s','m'}));
	const WOFF_BIT = @as(u32, @bitCast([4]u8{'w','o','f','f'}));
	const WEBP_BIT = @as(u32, @bitCast([4]u8{'w','e','b','p'}));
	const WOFF2_BIT = @as(u40, @bitCast([5]u8{'w','o','f','f', '2'}));

	pub fn forExtension(ext: []const u8) ContentType {
		if (ext.len == 0) return .UNKNOWN;
		const temp = if (ext[0] == '.') ext[1..] else ext;
		if (temp.len > 5) return .UNKNOWN;

		var normalized: [5]u8 = undefined;
		for (temp, 0..) |c, i| {
			normalized[i] = std.ascii.toLower(c);
		}

		switch (temp.len) {
			2 => {
				switch (@as(u16, @bitCast(normalized[0..2].*))) {
					JS_BIT => return .JS,
					GZ_BIT => return .GZ,
					else => return .UNKNOWN,
				}
			},
			3 => {
				switch (@as(u24, @bitCast(normalized[0..3].*))) {
					CSS_BIT => return .CSS,
					CSV_BIT => return .CSV,
					EOT_BIT => return .EOT,
					GIF_BIT => return .GIF,
					HTM_BIT => return .HTML,
					ICO_BIT => return .ICO,
					JPG_BIT => return .JPG,
					OTF_BIT => return .OTF,
					PDF_BIT => return .PDF,
					PNG_BIT => return .PNG,
					SVG_BIT => return .SVG,
					TAR_BIT => return .TAR,
					TTF_BIT => return .TTF,
					XML_BIT => return .XML,
					else => return .UNKNOWN,
				}
			},
			4 => {
				switch (@as(u32, @bitCast(normalized[0..4].*))) {
					JPEG_BIT => return .JPG,
					JSON_BIT => return .JSON,
					HTML_BIT => return .HTML,
					TEXT_BIT => return .TEXT,
					WASM_BIT => return .WASM,
					WOFF_BIT => return .WOFF,
					WEBP_BIT => return .WEBP,
					else => return .UNKNOWN,
				}
			},
			5 => {
				switch (@as(u40, @bitCast(normalized[0..5].*))) {
					WOFF2_BIT => return .WOFF2,
					else => return .UNKNOWN,
				}
			},
			else => return .UNKNOWN,
		}
		return .UNKNOWN;
	}

	pub fn forFile(file_name: []const u8) ContentType {
		return forExtension(std.fs.path.extension(file_name));
	}
};

pub fn Action(comptime G: type) type {
	if (G == void) {
		return *const fn(*Request, *Response) anyerror!void;
	}
	return *const fn(G, *Request, *Response) anyerror!void;
}

pub fn Dispatcher(comptime G: type, comptime R: type) type {
	if (G == void and R == void) {
		return *const fn(Action(void), *Request, *Response) anyerror!void;
	} else if (G == void) {
		return *const fn(Action(R), *Request, *Response) anyerror!void;
	} else if (R == void) {
		return *const fn(G, Action(G), *Request, *Response) anyerror!void;
	}
	return *const fn(G, Action(R), *Request, *Response) anyerror!void;
}

pub fn DispatchableAction(comptime G: type, comptime R: type) type {
	return struct {
		ctx: G,
		action: Action(R),
		dispatcher: Dispatcher(G, R),
	};
}

fn ErrorHandlerAction(comptime G: type) type {
	if (G == void) {
		return *const fn(*Request, *Response, anyerror) void;
	}
	return *const fn(G, *Request, *Response, anyerror) void;
}

// Done this way so that Server and ServerCtx have a similar API
pub fn Server() type {
	return struct {
		pub fn init(allocator: Allocator, config: Config) !ServerCtx(void, void) {
			return try ServerCtx(void, void).init(allocator, config, {});
		}
	};
}

pub fn ServerCtx(comptime G: type, comptime R: type) type {
	return struct {
		ctx: G,
		config: Config,
		allocator: Allocator,
		_cors_origin: ?[]const u8,
		_router: Router(G, R),
		_errorHandler: ErrorHandlerAction(G),
		_notFoundHandler: Action(G),
		_cond: Thread.Condition,

		const Self = @This();
		const Worker = @import("worker.zig").Worker(*Self);

		pub fn init(allocator: Allocator, config: Config, ctx: G) !Self {
			const nfh = if (comptime G == void) defaultNotFound else defaultNotFoundWithContext;
			const erh = if (comptime G == void) defaultErrorHandler else defaultErrorHandlerWithContext;
			const dd = if (comptime G == void) defaultDispatcher else defaultDispatcherWithContext;

			var var_config = config;
			if (config.port == null) {
				var_config.port = 5882;
			}
			if (config.address == null) {
				var_config.address = "127.0.0.1";
			}

			return .{
				.ctx = ctx,
				.config = var_config,
				.allocator = allocator,
				._cond = .{},
				._errorHandler = erh,
				._notFoundHandler = nfh,
				._router = try Router(G, R).init(allocator, dd, ctx),
				._cors_origin = if (config.cors) |cors| cors.origin else null,
			};
		}

		pub fn deinit(self: *Self) void {
			self._router.deinit(self.allocator);
		}

		pub fn listen(self: *Self) !void {
			const os = std.os;
			const net = std.net;

			const config = self.config;

			var socket = net.StreamServer.init(.{
				.reuse_address = true,
				.kernel_backlog = 1024,
				.force_nonblocking = true,
			});
			defer socket.deinit();

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
				//  try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
				// }
				try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
			}

			const allocator = self.allocator;
			const signal = try os.pipe();

			const worker_count = config.workers.count orelse 2;
			const workers = try allocator.alloc(Worker, worker_count);
			const threads = try allocator.alloc(Thread, worker_count);

			var started: usize = 0;

			defer {
				socket.close();
				// should cause the workers to unblock
				os.close(signal[1]);

				for (0..started) |i| {
					threads[i].join();
					workers[i].deinit();
				}
				allocator.free(workers);
				allocator.free(threads);
			}


			for (0..workers.len) |i| {
				workers[i] = try Worker.init(allocator, allocator, self, &config);
				threads[i] = try Thread.spawn(.{}, Worker.run, .{&workers[i], &socket, signal[0]});
				started += 1;
			}

			// is this really the best way?
			var mutex = Thread.Mutex{};
			mutex.lock();
			self._cond.wait(&mutex);
			mutex.unlock();
		}

		pub fn listenInNewThread(self: *Self) !std.Thread {
			return try std.Thread.spawn(.{}, listen, .{self});
		}

		pub fn stop(self: *Self) void {
			self._cond.signal();
		}

		pub fn notFound(self: *Self, nfa: Action(G)) void {
			self._notFoundHandler = nfa;
		}

		pub fn errorHandler(self: *Self, eha: ErrorHandlerAction(G)) void {
			self._errorHandler = eha;
		}

		pub fn dispatcher(self: *Self, d: Dispatcher(G, R)) void {
			(&self._router).dispatcher(d);
		}

		pub fn router(self: *Self) *Router(G, R) {
			return &self._router;
		}

		fn defaultNotFoundWithContext(_:G, req: *Request, res: *Response) !void{
			try defaultNotFound(req, res);
		}

		fn defaultNotFound(_: *Request, res: *Response) !void {
			res.status = 404;
			res.body = "Not Found";
		}

		fn defaultErrorHandlerWithContext(_:G, req: *Request, res: *Response, err: anyerror) void {
			defaultErrorHandler(req, res, err);
		}

		fn defaultErrorHandler(req: *Request, res: *Response, err: anyerror) void {
			res.status = 500;
			res.body = "Internal Server Error";
			std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{req.url.raw, err});
		}

		fn defaultDispatcher(action: Action(R), req: *Request, res: *Response) !void {
			try action(req, res);
		}

		fn defaultDispatcherWithContext(ctx: G, action: Action(R), req: *Request, res: *Response) !void {
			if (R == G) {
				return action(ctx, req, res);
			}
			// app needs to provide a dispatcher in this case
			return error.CannotDispatch;
		}

		pub fn handle(self: Self, req: *Request, res: *Response) bool {
			const dispatchable_action = self._router.route(req.method, req.url.path, &req.params);
			self.dispatch(dispatchable_action, req, res) catch |err| switch (err) {
				error.BodyTooBig => {
					res.status = 431;
					res.body = "Request body is too big";
					res.write() catch return false;
				},
				error.BrokenPipe, error.ConnectionResetByPeer, error.Unexpected => {
					// TODO: maybe allow the user to set a different errorHandler for these sort of conditions
					return false;
				},
				else => {
					if (comptime G == void) {
						self._errorHandler(req, res, err);
					} else {
						const ctx = if (dispatchable_action) |da| da.ctx else self.ctx;
						self._errorHandler(ctx, req, res, err);
					}
				}
			};
			if (!req.canKeepAlive()) {
				res.keepalive = false;
			}
			res.write() catch return false;
			return res.keepalive;
		}

		inline fn dispatch(self: Self, dispatchable_action: ?DispatchableAction(G, R), req: *Request, res: *Response) !void {
			if (self._cors_origin) |origin| {
				res.header("Access-Control-Allow-Origin", origin);
			}
			if (dispatchable_action) |da| {
				if (G == void) {
					return da.dispatcher(da.action, req, res);
				}
				return da.dispatcher(da.ctx, da.action,req, res);
			}

			if (req.method == .OPTIONS) {
				if (self.config.cors) |config| {
					if (req.header("sec-fetch-mode")) |mode| {
						if (std.mem.eql(u8, mode, "cors")) {
							if (config.headers) |headers| {
								res.header("Access-Control-Allow-Headers", headers);
							}
							if (config.methods) |methods| {
								res.header("Access-Control-Allow-Methods", methods);
							}
							if (config.max_age) |max_age| {
								res.header("Access-Control-Max-Age", max_age);
							}
							res.status = 204;
							return;
						}
					}
				}
			}

			if (G == void) {
				return self._notFoundHandler(req, res);
			}
			return self._notFoundHandler(self.ctx, req, res);
		}
	};
}

const t = @import("t.zig");
var la = std.heap.GeneralPurposeAllocator(.{}){};

var default_server: *ServerCtx(void, void) = undefined;
var context_server: *ServerCtx(u32, u32) = undefined;
var cors_server: *ServerCtx(u32, u32) = undefined;

test {
	// this will leak since the server will run until the process exits. If we use
	// our testing allocator, it'll report the leak.
	const leaking_allocator = la.allocator();
	{
		default_server = try leaking_allocator.create(ServerCtx(void, void));
		default_server.* = try Server().init(leaking_allocator, .{.port = 5992});
		var router = default_server.router();
		router.get("/test/json", testJsonRes);
		router.get("/test/query", testReqQuery);
		router.get("/test/stream", testEventStream);
		router.allC("/test/dispatcher", testDispatcherAction, .{.dispatcher = testDispatcher1});
		var thread = try default_server.listenInNewThread();
		thread.detach();
	}

	{
		context_server = try leaking_allocator.create(ServerCtx(u32, u32));
		context_server.* = try ServerCtx(u32, u32).init(leaking_allocator, .{.port = 5993}, 3);
		context_server.notFound(testNotFound);
		var router = context_server.router();
		router.get("/", ctxEchoAction);
		router.get("/fail", testFail);
		router.post("/login", ctxEchoAction);
		router.get("/test/body/cl", testCLBody);
		router.get("/test/headers", testHeaders);
		router.all("/api/:version/users/:UserId", testParams);

		var admin_routes = router.group("/admin/", .{.dispatcher = ctxTestDispatcher2, .ctx = 99});
		admin_routes.get("/users", ctxEchoAction);
		admin_routes.put("/users/:id", ctxEchoAction);

		var debug_routes = router.group("/debug", .{.dispatcher = ctxTestDispatcher3, .ctx = 20});
		debug_routes.head("/ping", ctxEchoAction);
		debug_routes.options("/stats", ctxEchoAction);

		var thread = try context_server.listenInNewThread();
		thread.detach();
	}

	{
		cors_server = try leaking_allocator.create(ServerCtx(u32, u32));
		cors_server.* = try ServerCtx(u32, u32).init(leaking_allocator, .{
			.port = 5994,
			.cors = .{
				.origin = "httpz.local",
				.headers = "content-type",
				.methods = "GET,POST",
				.max_age = "300"
			},
		}, 100);
		var router = cors_server.router();
		router.all("/echo", ctxEchoAction);
		var thread = try cors_server.listenInNewThread();
		thread.detach();
	}

	std.testing.refAllDecls(@This());
}

test "httpz: invalid request" {
	const stream = testStream(5992);
	defer stream.close();
	try stream.writeAll("TEA / HTTP/1.1\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 400\r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "httpz: no route" {
	const stream = testStream(5992);
	defer stream.close();
	try stream.writeAll("GET / HTTP/1.1\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 404\r\nContent-Length: 9\r\n\r\nNot Found", testReadAll(stream, &buf));
}

test "httpz: no route with custom notFound handler" {
	const stream = testStream(5993);
	defer stream.close();
	try stream.writeAll("GET /not_found HTTP/1.1\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 404\r\nCtx: 3\r\nContent-Length: 10\r\n\r\nwhere lah?", testReadAll(stream, &buf));
}

test "httpz: unhandled exception" {
	std.testing.log_level = .err;
	defer std.testing.log_level = .warn;

	const stream = testStream(5993);
	defer stream.close();
	try stream.writeAll("GET /fail HTTP/1.1\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 500\r\nContent-Length: 21\r\n\r\nInternal Server Error", testReadAll(stream, &buf));
}

test "httpz: unhandled exception with custom error handler" {
	// should not be done like this, server isn't thread safe and shouldn't
	// be changed once listening, but greatly simplifies our testing.
	context_server.errorHandler(testErrorHandler);

	std.testing.log_level = .err;
	defer std.testing.log_level = .warn;

	const stream = testStream(5993);
	defer stream.close();
	try stream.writeAll("GET /fail HTTP/1.1\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 500\r\nCtx: 3\r\nContent-Length: 29\r\n\r\n#/why/arent/tags/hierarchical", testReadAll(stream, &buf));
}

test "httpz: route params" {
	const stream = testStream(5993);
	defer stream.close();
	try stream.writeAll("GET /api/v2/users/9001 HTTP/1.1\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 200\r\nContent-Length: 20\r\n\r\nversion=v2,user=9001", testReadAll(stream, &buf));
}

test "httpz: request and response headers" {
	const stream = testStream(5993);
	defer stream.close();
	try stream.writeAll("GET /test/headers HTTP/1.1\r\nHeader-Name: Header-Value\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 200\r\nCtx: 3\r\nEcho: Header-Value\r\nother: test-value\r\nContent-Length: 0\r\n\r\n", testReadAll(stream, &buf));
}

test "httpz: content-length body" {
	const stream = testStream(5993);
	defer stream.close();
	try stream.writeAll("GET /test/body/cl HTTP/1.1\r\nHeader-Name: Header-Value\r\nContent-Length: 4\r\n\r\nabcz");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 200\r\nEcho-Body: abcz\r\nContent-Length: 0\r\n\r\n", testReadAll(stream, &buf));
}

test "httpz: json response" {
	const stream = testStream(5992);
	defer stream.close();
	try stream.writeAll("GET /test/json HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 201\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"over\":9000,\"teg\":\"soup\"}", testReadAll(stream, &buf));
}

test "httpz: query" {
	const stream = testStream(5992);
	defer stream.close();
	try stream.writeAll("GET /test/query?fav=keemun%20te%61%21 HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 200\r\nContent-Length: 11\r\n\r\nkeemun tea!", testReadAll(stream, &buf));
}

test "httpz: custom dispatcher" {
	const stream = testStream(5992);
	defer stream.close();
	try stream.writeAll("HEAD /test/dispatcher HTTP/1.1\r\n\r\n");

	var buf: [100]u8 = undefined;
	try t.expectString("HTTP/1.1 200\r\ndispatcher: test-dispatcher-1\r\nContent-Length: 6\r\n\r\naction", testReadAll(stream, &buf));
}

test "httpz: router groups" {
	const stream = testStream(5993);
	defer stream.close();

	{
		try stream.writeAll("GET / HTTP/1.1\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();

		try res.expectJson(.{.ctx = 3, .method = "GET", .path = "/"});
		try t.expectEqual(true, res.headers.get("dispatcher") == null);
	}

	{
		try stream.writeAll("GET /admin/users HTTP/1.1\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();

		try res.expectJson(.{.ctx = 99, .method = "GET", .path = "/admin/users"});
		try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
	}

	{
		try stream.writeAll("PUT /admin/users/:id HTTP/1.1\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();

		try res.expectJson(.{.ctx = 99, .method = "PUT", .path = "/admin/users/:id"});
		try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
	}

	{
		try stream.writeAll("HEAD /debug/ping HTTP/1.1\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();

		try res.expectJson(.{.ctx = 20, .method = "HEAD", .path = "/debug/ping"});
		try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
	}

	{
		try stream.writeAll("OPTIONS /debug/stats HTTP/1.1\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();

		try res.expectJson(.{.ctx = 20, .method = "OPTIONS", .path = "/debug/stats"});
		try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
	}

	{
		try stream.writeAll("POST /login HTTP/1.1\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();

		try res.expectJson(.{.ctx = 3, .method = "POST", .path = "/login"});
		try t.expectEqual(true, res.headers.get("dispatcher") == null);
	}
}

test "httpz: CORS" {
	const stream = testStream(5994);
	defer stream.close();

	{
		try stream.writeAll("GET /echo HTTP/1.1\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();
		try t.expectEqual(true, res.headers.get("Access-Control-Max-Age") == null);
		try t.expectEqual(true, res.headers.get("Access-Control-Allow-Methods") == null);
		try t.expectEqual(true, res.headers.get("Access-Control-Allow-Headers") == null);
		try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
	}

	{
		// non-cors options
		try stream.writeAll("OPTIONS /echo HTTP/1.1\r\nSec-Fetch-Mode: navigate\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();

		try t.expectEqual(true, res.headers.get("Access-Control-Max-Age") == null);
		try t.expectEqual(true, res.headers.get("Access-Control-Allow-Methods") == null);
		try t.expectEqual(true, res.headers.get("Access-Control-Allow-Headers") == null);
		try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
	}

	{
		// cors request
		try stream.writeAll("OPTIONS /no_route HTTP/1.1\r\nSec-Fetch-Mode: cors\r\n\r\n");
		var res = testReadParsed(stream);
		defer res.deinit();

		try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
		try t.expectString("GET,POST", res.headers.get("Access-Control-Allow-Methods").?);
		try t.expectString("content-type", res.headers.get("Access-Control-Allow-Headers").?);
		try t.expectString("300", res.headers.get("Access-Control-Max-Age").?);
	}
}

test "ContentType: forX" {
	inline for (@typeInfo(ContentType).Enum.fields) |field| {
		if (comptime std.mem.eql(u8, "BINARY", field.name)) continue;
		if (comptime std.mem.eql(u8, "EVENTS", field.name)) continue;
		try t.expectEqual(@field(ContentType, field.name), ContentType.forExtension(field.name));
		try t.expectEqual(@field(ContentType, field.name), ContentType.forExtension("." ++ field.name));
		try t.expectEqual(@field(ContentType, field.name), ContentType.forFile("some_file." ++ field.name));
	}
	// variations
	try t.expectEqual(ContentType.HTML, ContentType.forExtension(".htm"));
	try t.expectEqual(ContentType.JPG, ContentType.forExtension(".jpeg"));

	try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(".spice"));
	try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(""));
	try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(".x"));
	try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile(""));
	try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("css"));
	try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("css"));
	try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("must.spice"));
}

test "httpz: event stream" {
	const stream = testStream(5992);
	defer stream.close();
	try stream.writeAll("GET /test/stream HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

	var res = testReadParsed(stream);
	defer res.deinit();

	try t.expectEqual(818, res.status);
	try t.expectEqual(true, res.headers.get("Content-Length") == null);
	try t.expectString("text/event-stream", res.headers.get("Content-Type").?);
	try t.expectString("no-cache", res.headers.get("Cache-Control").?);
	try t.expectString("keep-alive", res.headers.get("Connection").?);
	try t.expectString("a message", res.body);
}

fn testFail(_: u32, _: *Request, _: *Response) !void {
	return error.TestUnhandledError;
}

fn testParams(_: u32, req: *Request, res: *Response) !void {
	const args = .{req.param("version").?, req.param("UserId").?};
	const out = try std.fmt.allocPrint(req.arena, "version={s},user={s}", args);
	res.body = out;
}

fn testHeaders(ctx: u32, req: *Request, res: *Response) !void {
	addContextHeader(res, ctx);
	res.header("Echo", req.header("header-name").?);
	res.header("other", "test-value");
}

fn testCLBody(_: u32, req: *Request, res: *Response) !void {
	res.header("Echo-Body", req.body().?);
}

fn testJsonRes(_: *Request, res: *Response) !void {
	res.status = 201;
	try res.json(.{.over = 9000, .teg = "soup"}, .{});
}

fn testEventStream(_: *Request, res: *Response) !void {
	res.status = 818;
	const stream = try res.startEventStream();
	try stream.writeAll("a message");
}

fn testReqQuery(req: *Request, res: *Response) !void {
	res.status = 200;
	const query = try req.query();
	res.body = query.get("fav").?;
}

fn testNotFound(ctx: u32, _: *Request, res: *Response) !void {
	res.status = 404;
	addContextHeader(res, ctx);
	res.body = "where lah?";
}

fn testErrorHandler(ctx: u32, _: *Request, res: *Response, _: anyerror) void {
	res.status = 500;
	addContextHeader(res, ctx);
	res.body = "#/why/arent/tags/hierarchical";
}

fn addContextHeader(res: *Response, ctx: u32) void {
	const value = std.fmt.allocPrint(res.arena, "{d}", .{ctx}) catch unreachable;
	res.header("Ctx", value);
}

fn testDispatcherAction(_: *Request, res: *Response) !void {
	return res.directWriter().writeAll("action");
}

fn testDispatcher1(action: Action(void), req: *Request, res: *Response) !void {
	res.header("dispatcher", "test-dispatcher-1");
	return action(req, res);
}

fn ctxTestDispatcher2(ctx: u32, action: Action(u32), req: *Request, res: *Response) !void {
	res.header("dispatcher", "test-dispatcher-2");
	return action(ctx, req, res);
}

fn ctxTestDispatcher3(ctx: u32, action: Action(u32), req: *Request, res: *Response) !void {
	res.header("dispatcher", "test-dispatcher-3");
	return action(ctx, req, res);
}

fn ctxEchoAction(ctx: u32, req: *Request, res: *Response) !void {
	return res.json(.{
		.ctx = ctx,
		.method = @tagName(req.method),
		.path = req.url.path,
	}, .{});
}

fn testStream(port: u16) std.net.Stream {
	const timeout = std.mem.toBytes(std.os.timeval{
		.tv_sec = 0,
		.tv_usec = 20_000,
	});

	const stream = std.net.tcpConnectToHost(t.allocator, "127.0.0.1", port) catch unreachable;
	std.os.setsockopt(stream.handle, std.os.SOL.SOCKET, std.os.SO.RCVTIMEO, &timeout) catch unreachable;
	std.os.setsockopt(stream.handle, std.os.SOL.SOCKET, std.os.SO.SNDTIMEO, &timeout) catch unreachable;
	return stream;
}

fn testReadAll(stream: std.net.Stream, buf: []u8) []u8 {
	var pos: usize = 0;
	while (true) {
		std.debug.assert(pos < buf.len);
		const n = stream.read(buf[pos..]) catch |err| switch (err) {
			error.WouldBlock => return buf[0..pos],
			else => @panic(@errorName(err)),
		};

		if (n == 0) {
			return buf[0..pos];
		}
		pos += n;
	}
	unreachable;
}

fn testReadParsed(stream: std.net.Stream) testing.Testing.Response {
	var buf: [1024]u8 = undefined;
	const data = testReadAll(stream, &buf);
	return testing.parse(data) catch unreachable;
}
