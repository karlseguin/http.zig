const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();

	var s = try httpz.Server.start(allocator, .{});
	try s.listen();
}
