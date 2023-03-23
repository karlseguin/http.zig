const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var server = try httpz.Server(void).init(allocator, {}, .{});
	var router = server.router();
	router.get("/", index);
	router.get("/hello", hello);
	router.get("/json/hello/:name", json);
	router.get("/writer/hello/:name", writer);
	try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response, _: void) !void {
	res.body = \\<!DOCTYPE html>
	\\ <ul>
	\\ <li><a href="/hello?name=Teg">/hello?name=Teg</a>
	\\ <li><a href="/json/hello/Duncan">/json/hello/Duncan</a>
	\\ <li><a href="/writer/hello/Ghanima">/writer/hello/Ghanima</a>
	;
}

fn hello(req: *httpz.Request, res: *httpz.Response, _: void) !void {
	const query = try req.query();
	const name = query.get("name") orelse "stranger";
	var out = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
	res.body = out;
}

fn json(req: *httpz.Request, res: *httpz.Response, _: void) !void {
	const name = req.param("name").?;
	try res.json(.{.hello = name});
}

fn writer(req: *httpz.Request, res: *httpz.Response, _: void) !void {
	res.content_type = httpz.ContentType.JSON;

	const name = req.param("name").?;
	var ws = std.json.writeStream(res.writer(), 4);
	try ws.beginObject();
	try ws.objectField("name");
	try ws.emitString(name);
	try ws.endObject();
}
