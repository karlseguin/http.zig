const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

// Our global state
const GlobalContext = struct {
	hits: usize = 0,
	l: std.Thread.Mutex = .{},

	pub fn increment(self: *GlobalContext, _: *httpz.Request, res: *httpz.Response) !void {
		self.l.lock();
		const hits = self.hits + 1;
		self.hits = hits;
		self.l.unlock();

		res.content_type = httpz.ContentType.TEXT;
		const out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
		res.body = out;
	}
};

// Started in main.zig which starts 3 servers, on 3 different ports, to showcase
// small variations in using httpz.
pub fn start(allocator: Allocator) !void {
	var ctx = GlobalContext{};
	var server = try httpz.ServerCtx(*GlobalContext, *GlobalContext).init(allocator, .{.port = 5883}, &ctx);
	defer server.deinit();
	var router = server.router();
	router.get("/increment", GlobalContext.increment);
	return server.listen();
}
