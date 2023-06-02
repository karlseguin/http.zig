const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
pub const testing = @import("testing.zig");

pub const routing = @import("router.zig");
pub const request = @import("request.zig");
pub const listener = @import("listener.zig");
pub const response = @import("response.zig");

pub const Router = routing.Router;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Url = @import("url.zig").Url;
pub const Config = @import("config.zig").Config;
const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;

const Allocator = std.mem.Allocator;

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
	GIF,
	GZ,
	HTML,
	ICO,
	JPG,
	JS,
	JSON,
	PDF,
	PNG,
	SVG,
	TAR,
	TEXT,
	WEBP,
	XML,
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
		app_allocator: Allocator,
		httpz_allocator: Allocator,
		_router: Router(G, R),
		_errorHandler: ErrorHandlerAction(G),
		_notFoundHandler: Action(G),

		const Self = @This();

		pub fn init(allocator: Allocator, config: Config, ctx: G) !Self {
			const nfh = if (comptime G == void) defaultNotFound else defaultNotFoundWithContext;
			const erh = if (comptime G == void) defaultErrorHandler else defaultErrorHandlerWithContext;
			const dd = if (comptime G == void) defaultDispatcher else defaultDispatcherWithContext;

			return .{
				.ctx = ctx,
				.config = config,
				.app_allocator = allocator,
				.httpz_allocator = allocator,
				._errorHandler = erh,
				._notFoundHandler = nfh,
				._router = try Router(G, R).init(allocator, dd, ctx),
			};
		}

		pub fn deinit(self: *Self) void {
			self._router.deinit(self.httpz_allocator);
		}

		pub fn listen(self: *Self) !void {
			try listener.listen(*ServerCtx(G, R), self.httpz_allocator, self.app_allocator, self, self.config);
		}

		pub fn listenInNewThread(self: *Self) !std.Thread {
			return try std.Thread.spawn(.{}, listen, .{self});
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
				else => {
					if (comptime G == void) {
						self._errorHandler(req, res, err);
					} else {
						const ctx = if (dispatchable_action) |da| da.ctx else self.ctx;
						self._errorHandler(ctx, req, res, err);
					}
				}
			};
			res.write() catch return false;
			return req.canKeepAlive();
		}

		inline fn dispatch(self: Self, dispatchable_action: ?DispatchableAction(G, R), req: *Request, res: *Response) !void {
			if (dispatchable_action) |da| {
				if (G == void) {
					return da.dispatcher(da.action, req, res);
				}
				return da.dispatcher(da.ctx, da.action,req, res);
			}

			if (G == void) {
				return self._notFoundHandler(req, res);
			}
			return self._notFoundHandler(self.ctx, req, res);
		}
	};
}

test {
	std.testing.refAllDecls(@This());
}

test "httpz: invalid request (not enough data, assume closed)" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 1) catch unreachable;
	defer srv.deinit();
	testRequest(u32, &srv, stream);

	try t.expectEqual(true, stream.closed);
	try t.expectEqual(@as(usize, 0), stream.received.items.len);
}

test "httpz: invalid request" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("TEA / HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 1) catch unreachable;
	defer srv.deinit();
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 400\r\nContent-Length: 15\r\n\r\nInvalid Request", stream.received.items);
}

test "httpz: no route" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 1) catch unreachable;
	defer srv.deinit();
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 404\r\nContent-Length: 9\r\n\r\nNot Found", stream.received.items);
}

test "httpz: no route with custom notFound handler" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 3) catch unreachable;
	defer srv.deinit();
	srv.notFound(testNotFound);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 404\r\nCtx: 3\r\nContent-Length: 10\r\n\r\nwhere lah?", stream.received.items);
}

test "httpz: unhandled exception" {
	std.testing.log_level = .err;
	defer std.testing.log_level = .warn;

	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /fail HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 5) catch unreachable;
	defer srv.deinit();
	srv.router().get("/fail", testFail);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 500\r\nContent-Length: 21\r\n\r\nInternal Server Error", stream.received.items);
}

test "httpz: unhandled exception with custom error handler" {
	std.testing.log_level = .err;
	defer std.testing.log_level = .warn;

	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /fail HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 4) catch unreachable;
	defer srv.deinit();
	srv.errorHandler(testErrorHandler);
	srv.router().get("/fail", testFail);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 500\r\nCtx: 4\r\nContent-Length: 29\r\n\r\n#/why/arent/tags/hierarchical", stream.received.items);
}

test "httpz: route params" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /api/v2/users/9001 HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 1) catch unreachable;
	defer srv.deinit();
	srv.router().all("/api/:version/users/:UserId", testParams);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 200\r\nContent-Length: 20\r\n\r\nversion=v2,user=9001", stream.received.items);
}

test "httpz: request and response headers" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/headers HTTP/1.1\r\nHeader-Name: Header-Value\r\n\r\n");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 88) catch unreachable;
	defer srv.deinit();
	srv.router().get("/test/headers", testHeaders);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 200\r\nCtx: 88\r\nEcho: Header-Value\r\nother: test-value\r\nContent-Length: 0\r\n\r\n", stream.received.items);
}

test "httpz: content-length body" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/body/cl HTTP/1.1\r\nHeader-Name: Header-Value\r\nContent-Length: 4\r\n\r\nabcz");

	var srv = ServerCtx(u32, u32).init(t.allocator, .{}, 1) catch unreachable;
	defer srv.deinit();
	srv.router().get("/test/body/cl", testCLBody);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 200\r\nEcho-Body: abcz\r\nContent-Length: 0\r\n\r\n", stream.received.items);
}

test "httpz: json response" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/json HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

	var srv = Server().init(t.allocator, .{}) catch unreachable;
	defer srv.deinit();
	srv.router().get("/test/json", testJsonRes);
	testRequest(void, &srv, stream);

	try t.expectString("HTTP/1.1 201\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"over\":9000,\"teg\":\"soup\"}", stream.received.items);
}

test "httpz: query" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/query?fav=keemun%20te%61%21 HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

	var srv = Server().init(t.allocator, .{}) catch unreachable;
	defer srv.deinit();
	srv.router().get("/test/query", testReqQuery);
	testRequest(void, &srv, stream);

	try t.expectString("HTTP/1.1 200\r\nContent-Length: 11\r\n\r\nkeemun tea!", stream.received.items);
}

test "httpz: custom dispatcher" {
	var stream = t.Stream.init();
	defer stream.deinit();

	var srv = Server().init(t.allocator, .{}) catch unreachable;
	defer srv.deinit();
	var router = srv.router();
	router.allC("/test/dispatcher", testDispatcherAction, .{.dispatcher = testDispatcher1});

	_ = stream.add("HEAD /test/dispatcher HTTP/1.1\r\n\r\n");
	testRequest(void, &srv, stream);
	try t.expectString("HTTP/1.1 200\r\ndispatcher: test-dispatcher-1\r\nContent-Length: 6\r\n\r\naction", stream.received.items);
}

test "httpz: router groups" {
	var srv = ServerCtx(i32, i32).init(t.allocator, .{}, 33) catch unreachable;
	defer srv.deinit();

	var router = srv.router();
	router.get("/", ctxEchoAction);

	var admin_routes = router.group("/admin", .{.dispatcher = ctxTestDispatcher2, .ctx = 99});
	admin_routes.get("/users", ctxEchoAction);
	admin_routes.put("/users/:id", ctxEchoAction);

	var debug_routes = router.group("/debug", .{.dispatcher = ctxTestDispatcher3, .ctx = 20});
	debug_routes.head("/ping", ctxEchoAction);
	debug_routes.option("/stats", ctxEchoAction);

	router.post("/login", ctxEchoAction);

	{
		var stream = t.Stream.init();
		defer stream.deinit();
		_ = stream.add("GET / HTTP/1.1\r\n\r\n");

		testRequest(i32, &srv, stream);
		var res = try testing.parse(stream.received.items);
		defer res.deinit();

		try res.expectJson(.{.ctx = 33, .method = "GET", .path = "/"});
		try t.expectEqual(true, res.headers.get("dispatcher") == null);
	}

	{
		var stream = t.Stream.init();
		defer stream.deinit();
		_ = stream.add("GET /admin/users HTTP/1.1\r\n\r\n");

		testRequest(i32, &srv, stream);
		var res = try testing.parse(stream.received.items);
		defer res.deinit();

		try res.expectJson(.{.ctx = 99, .method = "GET", .path = "/admin/users"});
		try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
	}

	{
		var stream = t.Stream.init();
		defer stream.deinit();
		_ = stream.add("PUT /admin/users/:id HTTP/1.1\r\n\r\n");

		testRequest(i32, &srv, stream);
		var res = try testing.parse(stream.received.items);
		defer res.deinit();

		try res.expectJson(.{.ctx = 99, .method = "PUT", .path = "/admin/users/:id"});
		try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
	}

	{
		var stream = t.Stream.init();
		defer stream.deinit();
		_ = stream.add("HEAD /debug/ping HTTP/1.1\r\n\r\n");

		testRequest(i32, &srv, stream);
		var res = try testing.parse(stream.received.items);
		defer res.deinit();

		try res.expectJson(.{.ctx = 20, .method = "HEAD", .path = "/debug/ping"});
		try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
	}

	{
		var stream = t.Stream.init();
		defer stream.deinit();
		_ = stream.add("OPTIONS /debug/stats HTTP/1.1\r\n\r\n");

		testRequest(i32, &srv, stream);
		var res = try testing.parse(stream.received.items);
		defer res.deinit();

		try res.expectJson(.{.ctx = 20, .method = "OPTIONS", .path = "/debug/stats"});
		try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
	}

	{
		var stream = t.Stream.init();
		defer stream.deinit();
		_ = stream.add("POST /login HTTP/1.1\r\n\r\n");

		testRequest(i32, &srv, stream);
		var res = try testing.parse(stream.received.items);
		defer res.deinit();

		try res.expectJson(.{.ctx = 33, .method = "POST", .path = "/login"});
		try t.expectEqual(true, res.headers.get("dispatcher") == null);
	}
}

fn testRequest(comptime G: type, srv: *ServerCtx(G, G), stream: *t.Stream) void {
	var reqResPool = listener.initReqResPool(t.allocator, t.allocator, .{
		.pool_size = 2,
		.request = .{.buffer_size = 4096},
		.response = .{.body_buffer_size = 4096},
	}) catch unreachable;
	defer reqResPool.deinit();
	listener.handleConnection(*ServerCtx(G, G), srv, stream, &reqResPool);
}

fn testFail(_: u32, _: *Request, _: *Response) !void {
	return error.TestUnhandledError;
}

fn testParams(_: u32, req: *Request, res: *Response) !void {
	var args = .{req.param("version").?, req.param("UserId").?};
	var out = try std.fmt.allocPrint(req.arena, "version={s},user={s}", args);
	res.body = out;
}

fn testHeaders(ctx: u32, req: *Request, res: *Response) !void {
	addContextHeader(res, ctx);
	res.header("Echo", req.header("header-name").?);
	res.header("other", "test-value");
}

fn testCLBody(_: u32, req: *Request, res: *Response) !void {
	const body = try req.body();
	res.header("Echo-Body", body.?);
}

fn testJsonRes(_: *Request, res: *Response) !void {
	res.status = 201;
	try res.json(.{.over = 9000, .teg = "soup"}, .{});
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

fn ctxTestDispatcher2(ctx: i32, action: Action(i32), req: *Request, res: *Response) !void {
	res.header("dispatcher", "test-dispatcher-2");
	return action(ctx, req, res);
}

fn ctxTestDispatcher3(ctx: i32, action: Action(i32), req: *Request, res: *Response) !void {
	res.header("dispatcher", "test-dispatcher-3");
	return action(ctx, req, res);
}

fn ctxEchoAction(ctx: i32, req: *Request, res: *Response) !void {
	return res.json(.{
		.ctx = ctx,
		.method = @tagName(req.method),
		.path = req.url.path,
	}, .{});
}
