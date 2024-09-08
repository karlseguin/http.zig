const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const PORT = 8805;

// This example uses the Handler's "handle" function to completely takeover
// request processing from httpz.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var handler = Handler{};
    var server = try httpz.Server(*Handler).init(allocator, .{ .port = PORT }, &handler);

    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    // Routes aren't used in this mode

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

const Handler = struct {
    pub fn handle(_: *Handler, _: *httpz.Request, res: *httpz.Response) void {
        res.body =
            \\ If defined, the "handle" function is called early in httpz' request
            \\ processing. Routing, middlewares, not found and error handling are all skipped.
            \\ This is an advanced option and is used by frameworks like JetZig to provide
            \\ their own flavor and enhancement ontop of httpz.
            \\ If you define this, the special "dispatch", "notFound" and "uncaughtError"
            \\ functions have no meaning as far as httpz is concerned.
        ;
    }
};
