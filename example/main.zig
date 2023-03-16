const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var router = try httpz.router(allocator);
	try router.get("/ping", ping);
	try httpz.listen(allocator, &router, .{
		.request = .{
			.buffer_size = 20,
		}
	});
}

fn ping(_: *httpz.Request, res: *httpz.Response) !void {
	res.setBody("ok!");
}
