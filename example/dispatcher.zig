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
    const Self = @This();

    user_id: ?[]const u8,
    global: *GlobalContext,

    pub fn increment(self: *Self, _: *httpz.Request, res: *httpz.Response) !void {
        // we don't actually do anything with ctx.user_id
        // except make sure it's been set. This could be common in a route
        // where any user can take an action as long as they're logged in.

        if (self.user_id == null) return notAuthorized(res);

        self.global.l.lock();
        var hits = self.global.hits + 1;
        self.global.hits = hits;
        self.global.l.unlock();

        res.content_type = httpz.ContentType.TEXT;
        var out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
        res.body = out;
    }
};

pub fn start(allocator: Allocator) !void {
    var ctx = GlobalContext{};
    var server = try httpz.ServerCtx(*GlobalContext, *RequestContext).init(allocator, .{ .pool_size = 10, .port = 5884 }, &ctx);
    server.dispatcher(dispatcher);
    var router = server.router();
    router.get("/increment", RequestContext.increment);
    return server.listen();
}

fn notAuthorized(res: *httpz.Response) void {
    res.status = 401;
    res.body = "Not authorized";
}

fn dispatcher(global: *GlobalContext, action: httpz.Action(*RequestContext), req: *httpz.Request, res: *httpz.Response) !void {
    // If we you need to allocate memory here, consider using req.arena

    // this is obviously a dummy example where we just trust the "user" header
    var ctx = RequestContext{
        .global = global,
        .user_id = req.header("user"),
    };
    return action(&ctx, req, res);
}
