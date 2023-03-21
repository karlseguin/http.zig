const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var router = try httpz.router(allocator);
	try router.get("/", index);
	try router.get("/hello", hello);
	try router.get("/json/hello/:name", json);
	try router.get("/writer/hello/:name", writer);
	try httpz.listen(allocator, &router, .{});
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
	res.body = \\<!DOCTYPE html>
	\\ <ul>
	\\ <li><a href="/hello?name=Teg">/hello?name=Teg</a>
	\\ <li><a href="/json/hello/Duncan">/json/hello/Duncan</a>
	\\ <li><a href="/writer/hello/Ghanima">/writer/hello/Ghanima</a>
	;
}

fn hello(req: *httpz.Request, res: *httpz.Response) !void {
	const query = try req.query();
	const name = query.get("name") orelse "stranger";
	var out = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
	res.body = out;
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
