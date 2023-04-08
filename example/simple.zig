const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

pub fn start(allocator: Allocator) !void{
	var server = try httpz.Server().init(allocator, .{.pool_size = 10});
	var router = server.router();

	router.get("/", index, .{});
	router.get("/hello", hello, .{});
	router.get("/json/hello/:name", json, .{});
	router.get("/writer/hello/:name", writer, .{});
	try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
	res.body = \\<!DOCTYPE html>
	\\ <ul>
	\\ <li><a href="/hello?name=Teg">Querystring + text output</a>
	\\ <li><a href="/writer/hello/Ghanima">Path parameter + serialize json object</a>
	\\ <li><a href="/json/hello/Duncan">Path parameter + json writer</a>
	\\ <li><a href="http://localhost:5883/increment">Global shared state</a>
	;
}

fn hello(req: *httpz.Request, res: *httpz.Response) !void {
	const query = try req.query();
	const name = query.get("name") orelse "stranger";

	// One solution is to use res.arena
	// var out = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
	// res.body = out

	// another is to use res.writer(), which might be more efficient in some cases
	try std.fmt.format(res.writer(), "Hello {s}", .{name});
}

fn json(req: *httpz.Request, res: *httpz.Response) !void {
	const name = req.param("name").?;
	try res.json(.{.hello = name});
}

fn writer(req: *httpz.Request, res: *httpz.Response) !void {
	res.content_type = httpz.ContentType.JSON;

	const name = req.param("name").?;
	var ws = std.json.writeStream(res.writer(), 4);
	try ws.beginObject();
	try ws.objectField("name");
	try ws.emitString(name);
	try ws.endObject();
}
