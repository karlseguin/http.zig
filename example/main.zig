const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var router = try httpz.router(allocator);
	try router.get("/hello", hello);
	try httpz.listen(allocator, &router, .{});
}

fn hello(_: *httpz.Request, res: *httpz.Response) !void {
	res.content_type = httpz.ContentType.TEXT;
	res.setBody("Hello, World!");
}
