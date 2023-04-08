const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

// Our global state (just like global.zig)
const GlobalContext = struct {
	hits: usize = 0,
	l: std.Thread.Mutex = .{},
};

// our per-request data
const RequestContext = struct {
	user_id: ?u32,
	global: *GlobalContext,
};

pub fn start(allocator: Allocator) !void{
	var ctx = GlobalContext{};
	var server = try httpz.ServerCtx(*GlobalContext, *RequestContext).init(allocator, .{.pool_size = 10, .port = 5884}, &ctx);
	server.dispatcher(dispatcher);
	var router = server.router();
	router.get("/increment", increment, .{});
	return server.listen();
}

fn increment(_: *httpz.Request, res: *httpz.Response, ctx: *RequestContext) !void {
	// we don't actually do anything with ctx.user_id
	// except make sure it's been set. This could be common in a route
	// where any user can take an action as long as they're logged in.

	if (ctx.user_id == null) return notAuthorized(res);

	ctx.global.l.lock();
	var hits = ctx.global.hits + 1;
	ctx.global.hits = hits;
	ctx.global.l.unlock();

	res.content_type = httpz.ContentType.TEXT;
	var out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
	res.body = out;
}

fn notAuthorized(res: *httpz.Response) void {
	res.status = 401;
	res.body = "Not authorized";
}

fn dispatcher(action: httpz.Action(*RequestContext), req: *httpz.Request, res: *httpz.Response, global: *GlobalContext) !void {
	// If we you need to allocate memory here, consider using req.arena
	var ctx = RequestContext{
		.user_id = 9001,
		.global = global,
	};
	return action(req, res, &ctx);
}
