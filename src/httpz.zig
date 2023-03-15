const std = @import("std");

const t = @import("t.zig");
pub const server = @import("server.zig");
pub const router = @import("router.zig");

const Stream = @import("stream.zig").Stream;
pub const Config = @import("config.zig").Config;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;

const Allocator = std.mem.Allocator;

pub const Server = server.Server;
pub const Handler = server.Handler;
pub const Router = router.Router(router.Action);

pub fn listen(allocator: Allocator, r: *Router, config: Config) !void {
	const handler = Handler{.router = r};
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


test {
	std.testing.refAllDecls(@This());
}

test "httpz: invalid request (not enough data, assume closed)" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r");

	var r = Router.init(t.allocator) catch unreachable;
	var srv = testServer(&r);
	defer srv.deinit();
	srv.handleConnection(*t.Stream, &stream);

	try t.expectEqual(true, stream.closed);
	try t.expectEqual(@as(usize, 0), stream.received.items.len);
}

test "httpz: invalid request" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("TEA / HTTP/1.1\r\n\r\n");

	var r = Router.init(t.allocator) catch unreachable;
	var srv = testServer(&r);
	defer srv.deinit();
	srv.handleConnection(*t.Stream, &stream);

	try t.expectString("HTTP/1.1 400\r\nContent-Length: 15\r\n\r\nInvalid Request", stream.received.items);
}

test "httpz: no route" {
	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET / HTTP/1.1\r\n\r\n");

	var r = Router.init(t.allocator) catch unreachable;
	var srv = testServer(&r);
	defer srv.deinit();
	srv.handleConnection(*t.Stream, &stream);

	try t.expectString("HTTP/1.1 404\r\nContent-Length: 9\r\n\r\nNot Found", stream.received.items);
}

test "httpz: unhandled exception" {
	std.testing.log_level = .err;
	defer std.testing.log_level = .warn;

	var stream = t.Stream.init();
	defer stream.deinit();
	_ = stream.add("GET /fail HTTP/1.1\r\n\r\n");

	var r = Router.init(t.allocator) catch unreachable;
	try r.get("/fail", testFail);
	var srv = testServer(&r);
	defer srv.deinit();
	srv.handleConnection(*t.Stream, &stream);

	try t.expectString("HTTP/1.1 500\r\nContent-Length: 21\r\n\r\nInternal Server Error", stream.received.items);
}

fn testServer(r: *Router) Server(Handler) {
	const handler = Handler{.router = r};
	return Server(Handler).init(t.allocator, handler, .{}) catch unreachable;
}

fn testFail(_: *Request, _: *Response) !void {
	return error.TestUnhandledError;
}
