const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

// Our global state
const GlobalContext = struct {
	hits: usize = 0,
	l: std.Thread.Mutex = .{},
};

pub fn start(allocator: Allocator) !void{
	var ctx = GlobalContext{};
	var server = try httpz.ServerCtx(*GlobalContext, *GlobalContext).init(allocator, .{.pool_size = 10, .port = 5883}, &ctx);
	var router = server.router();
	router.get("/increment", increment, .{});
	return server.listen();
}

fn increment(_: *httpz.Request, res: *httpz.Response, ctx: *GlobalContext) !void {
	ctx.l.lock();
	var hits = ctx.hits + 1;
	ctx.hits = hits;
	ctx.l.unlock();

	res.content_type = httpz.ContentType.TEXT;
	var out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
	res.body = out;
}
