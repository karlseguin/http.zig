const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var router = try httpz.router(allocator);
	try router.get("/", index);
	try router.get("/hello", hello);
	try router.get("/json/hello/:name", json);
	try httpz.listen(allocator, &router, .{});
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
	res.body = \\<!DOCTYPE html>
	\\ <ul>
	\\ <li><a href="/hello?name=Teg">/hello?name=Teg</a>
	\\ <li><a href="/json/hello/Duncan">/json/hello/Duncan</a>
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
