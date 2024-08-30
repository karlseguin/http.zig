const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

// Started in main.zig which starts 3 servers, on 3 different ports, to showcase
// small variations in using httpz.
pub fn start(allocator: Allocator) !void {
    var handler = Handler{};
    var server = try httpz.Server(*Handler).init(allocator, .{ .port = 5883 }, &handler);
    defer server.deinit();
    var router = server.router();
    router.get("/increment", increment, .{});
    return server.listen();
}

// Our handler
const Handler = struct {
    hits: usize = 0,
    mut: std.Thread.Mutex = .{},
};

// since Handler is the firt parameter, this could also be a method of the Handler
// struct.
pub fn increment(h: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    h.mut.lock();
    const hits = h.hits + 1;
    h.hits = hits;
    h.mut.unlock();

    res.content_type = httpz.ContentType.TEXT;
    res.body = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
}
