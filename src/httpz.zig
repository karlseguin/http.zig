const std = @import("std");

const t = @import("t.zig");
pub const server = @import("server.zig");
pub const routing = @import("router.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");

pub const Config = @import("config.zig").Config;

const Allocator = std.mem.Allocator;
pub const Server = server.Server;
pub const Handler = server.Handler;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Router = routing.Router(Action);
pub const Action = *const fn(req: *Request, res: *Response) anyerror!void;
pub const ActionError = *const fn(err: anyerror, req: *Request, res: *Response) void;

// We provide this wrapper around init so that we can inject server.notFound
// as a default notFound route. The caller can always overwrite this by calling
// router.notFound(ACTION). But by having a default, we can define it, as well
// as the getRoute functions are non-nullable, which streamlines important code.
pub fn router(allocator: Allocator) !Router{
	return Router.init(allocator, server.notFound);
}

pub fn listen(allocator: Allocator, routes: *Router, config: Config) !void {
	const handler = Handler{.router = routes, .errorHandler = config.errorHandler};
	var s = try Server(Handler).init(allocator, handler, config);
	try s.listen();
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

	var rtr = router(t.allocator) catch unreachable;
	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectEqual(true, stream.closed);
	try t.expectEqual(@as(usize, 0), stream.received.items.len);
}

test "httpz: invalid request" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("TEA / HTTP/1.1\r\n\r\n");

	var rtr = router(t.allocator) catch unreachable;
	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 400\r\nContent-Length: 15\r\n\r\nInvalid Request", stream.received.items);
}

test "httpz: no route" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r\n\r\n");

	var rtr = router(t.allocator) catch unreachable;
	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 404\r\nContent-Length: 9\r\n\r\nNot Found", stream.received.items);
}

test "httpz: no route with custom notFound handler" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r\n\r\n");

	var rtr = router(t.allocator) catch unreachable;
	rtr.notFound(testNotFound);

	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 404\r\nContent-Length: 10\r\n\r\nwhere lah?", stream.received.items);
}

test "httpz: unhandled exception" {
	std.testing.log_level = .err;
	defer std.testing.log_level = .warn;

	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /fail HTTP/1.1\r\n\r\n");

	var rtr = router(t.allocator) catch unreachable;
	rtr.get("/fail", testFail);
	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 500\r\nContent-Length: 21\r\n\r\nInternal Server Error", stream.received.items);
}

test "httpz: unhandled exception with custom error handler" {
	std.testing.log_level = .err;
	defer std.testing.log_level = .warn;

	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /fail HTTP/1.1\r\n\r\n");

	var rtr = router(t.allocator) catch unreachable;
	rtr.get("/fail", testFail);
	var srv = testServer(&rtr, .{.errorHandler = testErrorHandler});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 500\r\nContent-Length: 29\r\n\r\n#/why/arent/tags/hierarchical", stream.received.items);
}

test "httpz: route params" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /api/v2/users/9001 HTTP/1.1\r\n\r\n");

	var rtr = router(t.allocator) catch unreachable;
	rtr.all("/api/:version/users/:UserId", testParams);
	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 200\r\nContent-Length: 20\r\n\r\nversion=v2,user=9001", stream.received.items);
}

test "httpz: request and response headers" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/headers HTTP/1.1\r\nHeader-Name: Header-Value\r\n\r\n");

	var rtr = router(t.allocator) catch unreachable;
	rtr.get("/test/headers", testHeaders);
	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 200\r\nEcho: Header-Value\r\nother: test-value\r\nContent-Length: 0\r\n\r\n", stream.received.items);
}

test "httpz: content-length body" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/body/cl HTTP/1.1\r\nHeader-Name: Header-Value\r\nContent-Length: 4\r\n\r\nabcz");

	var rtr = router(t.allocator) catch unreachable;
	rtr.get("/test/body/cl", testCLBody);
	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 200\r\nEcho-Body: abcz\r\nContent-Length: 0\r\n\r\n", stream.received.items);
}

test "httpz: json response" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /test/json HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

	var rtr = router(t.allocator) catch unreachable;
	rtr.get("/test/json", testJsonRes);
	var srv = testServer(&rtr, .{});
	defer srv.deinit();
	srv.handleConnection(stream);

	try t.expectString("HTTP/1.1 201\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"over\":9000,\"teg\":\"soup\"}", stream.received.items);
}

fn testServer(rtr: *Router, config: Config) Server(Handler) {
	const handler = Handler{.router = rtr, .errorHandler = config.errorHandler};
	return Server(Handler).init(t.allocator, handler, config) catch unreachable;
}

fn testFail(_: *Request, _: *Response) !void {
	return error.TestUnhandledError;
}

fn testParams(req: *Request, res: *Response) !void {
	var args = .{req.param("version").?, req.param("UserId").?};
	var out = try std.fmt.allocPrint(req.arena, "version={s},user={s}", args);
	res.body = out;
}

fn testHeaders(req: *Request, res: *Response) !void {
	res.header("Echo", req.header("header-name").?);
	res.header("other", "test-value");
}

fn testCLBody(req: *Request, res: *Response) !void {
	const body = try req.body();
	res.header("Echo-Body", body.?);
}

fn testJsonRes(_: *Request, res: *Response) !void {
	res.status = 201;
	try res.json(.{.over = 9000, .teg = "soup" });
}

fn testNotFound(_: *Request, res: *Response) !void {
	res.status = 404;
	res.body = "where lah?";
}

fn testErrorHandler(_: anyerror, _: *Request, res: *Response) void {
	res.status = 500;
	res.body = "#/why/arent/tags/hierarchical";
}
