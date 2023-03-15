const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var router = try httpz.Router.init(allocator);
	try router.get("/ping", ping);
	try httpz.listen(allocator, &router, .{});
}

fn ping(_: *httpz.Request, res: *httpz.Response) !void {
	res.status = 200;
	res.text("ok!");
}
