const std = @import("std");
const httpz = @import("httpz");

const Allocator = std.mem.Allocator;

const PORT = 8807;

// This example shows more advanced routing example, namely route groups
// and route configuration. (The previous example, with middleware, also showed
// per-route configuration for middleware specifically).

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var default_handler = Handler{
        .log = true,
    };

    var nolog_handler = Handler{
        .log = false,
    };

    var server = try httpz.Server(*Handler).init(allocator, .{ .port = PORT }, &default_handler);

    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = server.router(.{});

    router.get("/", index, .{});

    // We can define a dispatch function per-route. This will be used instead of Handler.dispatch
    // But, sadly, every dispatch method must have the same signature (they must all accept the same type of action)
    router.get("/page1", page1, .{ .dispatcher = Handler.infoDispatch });

    // We can define a handler instance per-route. This will be used instead of the
    // handler instance passed to the init method above.
    router.get("/page2", page2, .{ .handler = &nolog_handler });

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

const Handler = struct {
    log: bool,

    // special dispatch set in the info route
    pub fn infoDispatch(h: *Handler, action: httpz.Action(*Handler), req: *httpz.Request, res: *httpz.Response) !void {
        return action(h, req, res);
    }

    pub fn dispatch(h: *Handler, action: httpz.Action(*Handler), req: *httpz.Request, res: *httpz.Response) !void {
        try action(h, req, res);
        if (h.log) {
            std.debug.print("ts={d} path={s} status={d}\n", .{ std.time.timestamp(), req.url.path, res.status });
        }
    }
};

fn index(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\ <p>It's possible to define a custom dispatch method, custom handler instance and/or custom middleware per-route.
        \\ <p>It's also possible to create a route group, which is a group of routes who share a common prefix and/or a custom configration.
        \\ <ul>
        \\ <li><a href="/page1">page with custom dispatch</a>
        \\ <li><a href="/page2">page with custom handler</a>
    ;
}

fn page1(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    // Called with a custom config which specified a custom dispatch method
    res.body =
        \\ Accessing this endpoint will NOT generate a log line in the console,
        \\ because a custom dispatch method is used
    ;
}

fn page2(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    // Called with a custom config which specified a custom handler instance
    res.body =
        \\ Accessing this endpoint will NOT generate a log line in the console,
        \\ because a custom handler instance is used
    ;
}
