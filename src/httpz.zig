const std = @import("std");

const t = @import("t.zig");
pub const testing = @import("testing.zig");

pub const routing = @import("router.zig");
pub const request = @import("request.zig");
pub const listener = @import("listener.zig");
pub const response = @import("response.zig");

pub const Router = routing.Router;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Handler = listener.Handler;
pub const Config = @import("config.zig").Config;

const Allocator = std.mem.Allocator;

pub fn Action(comptime C: type) type {
	if (C == void) {
		return *const fn(*Request, *Response) anyerror!void;
	}
	return *const fn(*Request, *Response, C) anyerror!void;
}

pub fn ErrorHandlerAction(comptime C: type) type {
	if (C == void) {
		return *const fn(*Request, *Response, anyerror) void;
	}
	return *const fn(*Request, *Response, anyerror, C) void;
}

// Done this way so that Server and ServerCtx have a similar API
pub fn Server() type {
	return struct {
		pub fn init(allocator: Allocator,	config: Config) !ServerCtx(void) {
			return try ServerCtx(void).init(allocator, config, {});
		}
	};
}

pub fn ServerCtx(comptime C: type) type {
	return struct {
		config: Config,
		handler: Handler(C),
		allocator: Allocator,

		const Self = @This();

		pub fn init(allocator: Allocator, config: Config, ctx: C) !Self {
			const nfh = if (comptime C == void) defaultNotFound else defaultNotFoundWithContext;
			const erh = if (comptime C == void) defaultErrorHandler else defaultErrorHandlerWithContext;

			const handler = Handler(C){
				.ctx = ctx,
				.errorHandler = erh,
				.router = try Router(C).init(allocator, nfh),
			};

			return .{
				.config = config,
				.handler = handler,
				.allocator = allocator,
			};
		}

		pub fn deinit(self: *Self) void {
			self.handler.deinit();
		}

		pub fn listen(self: *Self) !void {
			try listener.listen(*Handler(C), self.allocator, &self.handler, self.config);
		}

		pub fn listenInNewThread(self: *Self) !std.Thread {
			return try std.Thread.spawn(.{}, listen, .{self});
		}

		pub fn router(self: *Self) *Router(C) {
			return &self.handler.router;
		}

		pub fn notFound(self: *Self, nfa: Action(C)) void {
			(&self.handler.router).notFound(nfa);
		}

		pub fn errorHandler(self: *Self, eha: ErrorHandlerAction(C)) void {
			(&self.handler).errorHandler = eha;
		}

		fn defaultNotFoundWithContext(req: *Request, res: *Response, _: C) !void{
			try defaultNotFound(req, res);
		}

		fn defaultNotFound(_: *Request, res: *Response) !void {
			res.status = 404;
			res.body = "Not Found";
		}

		fn defaultErrorHandlerWithContext(req: *Request, res: *Response, err: anyerror, _: C) void {
			defaultErrorHandler(req, res, err);
		}

		fn defaultErrorHandler(req: *Request, res: *Response, err: anyerror) void {
			res.status = 500;
			res.body = "Internal Server Error";
			std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{req.url.raw, err});
		}
	};
}

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

test {
	std.testing.refAllDecls(@This());
}

test "httpz: invalid request (not enough data, assume closed)" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r");

	var srv = ServerCtx(u32).init(t.allocator, .{}, 1) catch unreachable;
	testRequest(u32, &srv, stream);

	try t.expectEqual(true, stream.closed);
	try t.expectEqual(@as(usize, 0), stream.received.items.len);
}

test "httpz: invalid request" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("TEA / HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32).init(t.allocator, .{}, 1) catch unreachable;
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 400\r\nContent-Length: 15\r\n\r\nInvalid Request", stream.received.items);
}

test "httpz: no route" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32).init(t.allocator, .{}, 1) catch unreachable;
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 404\r\nContent-Length: 9\r\n\r\nNot Found", stream.received.items);
}

test "httpz: no route with custom notFound handler" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32).init(t.allocator, .{}, 3) catch unreachable;
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

	var srv = ServerCtx(u32).init(t.allocator, .{}, 5) catch unreachable;
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

	var srv = ServerCtx(u32).init(t.allocator, .{}, 4) catch unreachable;
	srv.errorHandler(testErrorHandler);
	srv.router().get("/fail", testFail);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 500\r\nCtx: 4\r\nContent-Length: 29\r\n\r\n#/why/arent/tags/hierarchical", stream.received.items);
}

test "httpz: route params" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /api/v2/users/9001 HTTP/1.1\r\n\r\n");

	var srv = ServerCtx(u32).init(t.allocator, .{}, 1) catch unreachable;
	srv.router().all("/api/:version/users/:UserId", testParams);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 200\r\nContent-Length: 20\r\n\r\nversion=v2,user=9001", stream.received.items);
}

test "httpz: request and response headers" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/headers HTTP/1.1\r\nHeader-Name: Header-Value\r\n\r\n");

	var srv = ServerCtx(u32).init(t.allocator, .{}, 88) catch unreachable;
	srv.router().get("/test/headers", testHeaders);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 200\r\nCtx: 88\r\nEcho: Header-Value\r\nother: test-value\r\nContent-Length: 0\r\n\r\n", stream.received.items);
}

test "httpz: content-length body" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/body/cl HTTP/1.1\r\nHeader-Name: Header-Value\r\nContent-Length: 4\r\n\r\nabcz");

	var srv = ServerCtx(u32).init(t.allocator, .{}, 1) catch unreachable;
	srv.router().get("/test/body/cl", testCLBody);
	testRequest(u32, &srv, stream);

	try t.expectString("HTTP/1.1 200\r\nEcho-Body: abcz\r\nContent-Length: 0\r\n\r\n", stream.received.items);
}

test "httpz: json response" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/json HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

	var srv = Server().init(t.allocator, .{}) catch unreachable;
	srv.router().get("/test/json", testJsonRes);
	testRequest(void, &srv, stream);

	try t.expectString("HTTP/1.1 201\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"over\":9000,\"teg\":\"soup\"}", stream.received.items);
}

test "httpz: query" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/query?fav=keemun%20te%61%21 HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

	var srv = Server().init(t.allocator, .{}) catch unreachable;
	srv.router().get("/test/query", testReqQuery);
	testRequest(void, &srv, stream);

	try t.expectString("HTTP/1.1 200\r\nContent-Length: 11\r\n\r\nkeemun tea!", stream.received.items);
}

fn testRequest(comptime C: type, srv: *ServerCtx(C), stream: *t.Stream) void {
	var reqResPool = listener.initReqResPool(t.allocator, t.allocator, .{
		.pool_size = 2,
		.request = .{.buffer_size = 4096},
		.response = .{.body_buffer_size = 4096},
	}) catch unreachable;
	defer reqResPool.deinit();
	defer srv.deinit();
	listener.handleConnection(Handler(C), srv.handler, stream, &reqResPool);
}

fn testFail(_: *Request, _: *Response, _: u32) !void {
	return error.TestUnhandledError;
}

fn testParams(req: *Request, res: *Response, _: u32) !void {
	var args = .{req.param("version").?, req.param("UserId").?};
	var out = try std.fmt.allocPrint(req.arena, "version={s},user={s}", args);
	res.body = out;
}

fn testHeaders(req: *Request, res: *Response, ctx: u32) !void {
	addContextHeader(res, ctx);
	res.header("Echo", req.header("header-name").?);
	res.header("other", "test-value");
}

fn testCLBody(req: *Request, res: *Response, _: u32) !void {
	const body = try req.body();
	res.header("Echo-Body", body.?);
}

fn testJsonRes(_: *Request, res: *Response) !void {
	res.status = 201;
	try res.json(.{.over = 9000, .teg = "soup" });
}

fn testReqQuery(req: *Request, res: *Response) !void {
	res.status = 200;
	const query = try req.query();
	res.body = query.get("fav").?;
}

fn testNotFound(_: *Request, res: *Response, ctx: u32) !void {
	res.status = 404;
	addContextHeader(res, ctx);
	res.body = "where lah?";
}

fn testErrorHandler(_: *Request, res: *Response, _: anyerror, ctx: u32) void {
	res.status = 500;
	addContextHeader(res, ctx);
	res.body = "#/why/arent/tags/hierarchical";
}

fn addContextHeader(res: *Response, ctx: u32) void {
	const value = std.fmt.allocPrint(res.arena, "{d}", .{ctx}) catch unreachable;
	res.header("Ctx", value);
}
