const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const PORT = 8803;

// This example uses a custom dispatch method on our handler for greater control
// in how actions are executed.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var handler = Handler{};
    var server = try httpz.Server(*Handler).init(allocator, .{ .port = PORT }, &handler);

    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = server.router(.{});

    router.get("/", index, .{});
    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

const Handler = struct {
    // In addition to the special "notFound" and "uncaughtError" shown in example 2
    // the special "dispatch" method can be used to gain more control over request handling.
    pub fn dispatch(self: *Handler, action: httpz.Action(*Handler), req: *httpz.Request, res: *httpz.Response) !void {
        // Our custom dispatch lets us add a log + timing for every request
        // httpz supports middlewares, but in many cases, having a dispatch is good
        // enough and is much more straightforward.

        var start = try std.time.Timer.start();
        // We don't _have_ to call the action if we don't want to. For example
        // we could do authentication and set the response directly on error.
        try action(self, req, res);

        std.debug.print("ts={d} us={d} path={s}\n", .{ std.time.timestamp(), start.lap() / 1000, req.url.path });
    }
};

fn index(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\ If defied, the dispatch method will be invoked for every request with a matching route.
        \\ It is up to dispatch to decide how/if the action should be called. While httpz
        \\ supports middleware, most cases can be more easily and cleanly handled with
        \\ a custom dispatch alone (you can always use both middlewares and a custom dispatch though).
        \\
        \\ Check out the console, our custom dispatch function times & logs each request.
    ;
}
