const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

// Our global state
const GlobalContext = struct {
    const Self = @This();

    hits: usize = 0,
    l: std.Thread.Mutex = .{},

    pub fn increment(self: *Self, _: *httpz.Request, res: *httpz.Response) !void {
        self.l.lock();
        var hits = self.hits + 1;
        self.hits = hits;
        self.l.unlock();

        res.content_type = httpz.ContentType.TEXT;
        var out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
        res.body = out;
    }
};

pub fn start(allocator: Allocator) !void {
    var ctx = GlobalContext{};
    var server = try httpz.ServerCtx(*GlobalContext, *GlobalContext).init(allocator, .{ .pool_size = 10, .port = 5883 }, &ctx);
    var router = server.router();
    router.get("/increment", GlobalContext.increment);
    return server.listen();
}
