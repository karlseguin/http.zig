const std = @import("std");
const httpz = @import("httpz");
const Logger = @import("middleware/Logger.zig");

const Allocator = std.mem.Allocator;

const PORT = 8806;

// This example show how to use and create middleware. There's overlap between
// what you can achieve with a custom dispatch function and per-route
// configuration (shown in the next example) and middleware.
// see

// See middleware/Logger.zig for an example of how to write a middleware

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try httpz.Server(void).init(allocator, .{ .port = PORT }, {});

    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    // creates an instance of the middleware with the given configuration
    // see example/middleware/Logger.zig
    const logger = try server.middleware(Logger, .{ .query = true });

    var router = server.router(.{});

    // Apply middleware to all routes created from this point on
    router.middlewares = &.{logger};

    router.get("/", index, .{});
    router.get("/other", other, .{ .middlewares = &.{} });

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\<p>There's overlap between a custom dispatch function and middlewares.
        \\<p>This page includes the example Logger middleware, so requesting it logs information.
        \\<p>The <a href="/other">other</a> endpoint uses a custom route config which
        \\   has no middleware, effectively disabling the Logger for that route.
    ;
}

fn other(_: *httpz.Request, res: *httpz.Response) !void {
    // Called with a custom config which had no middlewares
    // (effectively disabling the logging middleware)
    res.body =
        \\ Accessing this endpoint will NOT generate a log line in the console,
        \\ because the Logger middleware is disabled.
    ;
}
