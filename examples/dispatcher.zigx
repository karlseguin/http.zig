const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

pub fn start(allocator: Allocator) !void {
    var handler = Handler{};
    var server = try httpz.Server(*Handler).init(allocator, .{ .port = 5884 }, &handler);
    defer server.deinit();

    var router = server.router();
    router.get("/increment", increment, .{});
    return server.listen();
}

// Our handler (just like global.zig)
const Handler = struct {
    hits: usize = 0,
    mut: std.Thread.Mutex = .{},

    const Context = struct {
        handler: *Handler,
        user_id: ?[]const u8,
    };

    // "dispatch" is a special method, when the handler defines it, all request
    // will flow throw it with the matching route "action", which the dispatch
    // function is responsible for calling. In this "dispatch", you could implement
    // authentication, logging, or any other typical middleware behavior. You
    // do not HAVE to call the action.
    pub fn dispatch(handler: *Handler, action: httpz.Action(*Context), req: *httpz.Request, res: *httpz.Response) !void {
        // this is obviously a dummy example where we just trust the "user" header
        var ctx = Context{
            .handler = handler,
            .user_id = req.header("user"),
        };
        return action(&ctx, req, res);
    }
};

pub fn increment(ctx: *Handler.Context, _: *httpz.Request, res: *httpz.Response) !void {
    // we don't actually do anything with ctx.user_id
    // except make sure it's been set. This could be common in a route
    // where any user can take an action as long as they're logged in.
    if (ctx.user_id == null) {
        return notAuthorized(res);
    }

    ctx.handler.mut.lock();
    const hits = ctx.handler.hits + 1;
    ctx.handler.hits = hits;
    ctx.handler.mut.unlock();

    res.content_type = httpz.ContentType.TEXT;
    res.body = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
}

fn notAuthorized(res: *httpz.Response) !void {
    res.status = 401;
    res.body = "Not authorized";
}
