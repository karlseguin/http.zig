const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const PORT = 8801;

// This example demonstrates basic httpz usage, with focus on using the
// httpz.Request and httpz.Response objects.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // We pass a "void" handler. This is the simplest, but limits what we can do
    // The last parameter is an instance of our handler. Since we have
    // a void handler, we pass a void value: i.e. {}.
    var server = try httpz.Server(void).init(allocator, .{
        .address = .localhost(PORT),
        .request = .{
            // httpz has a number of tweakable configuration settings (see readme)
            // by default, it won't read form data. We need to configure a max
            // field count (since one of our examples reads form data)
            .max_form_count = 20,
        },
    }, {});
    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = try server.router(.{});

    // Register routes. The last parameter is a Route Config. For these basic
    // examples, we aren't using it.
    // Other support methods: post, put, delete, head, trace, options and all
    router.get("/", index, .{});
    router.get("/hello", hello, .{});
    router.get("/json/hello/:name", json, .{});
    router.get("/writer/hello/:name", writer, .{});
    router.get("/metrics", metrics, .{});
    router.get("/form_data", formShow, .{});
    router.post("/form_data", formPost, .{});
    router.get("/explicit_write", explicitWrite, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\<!DOCTYPE html>
        \\ <ul>
        \\ <li><a href="/hello?name=Teg">Querystring + text output</a>
        \\ <li><a href="/writer/hello/Ghanima">Path parameter + serialize json object</a>
        \\ <li><a href="/json/hello/Duncan">Path parameter + json writer</a>
        \\ <li><a href="/metrics">Internal metrics</a>
        \\ <li><a href="/form_data">Form Data</a>
        \\ <li><a href="/explicit_write">Explicit Write</a>
    ;
}

fn hello(req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const name = query.get("name") orelse "stranger";

    // Could also see res.writer(), see the writer endpoint for an example
    res.body = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
}

fn json(req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name").?;

    // the last parameter to res.json is an std.json.StringifyOptions
    try res.json(.{ .hello = name }, .{});
}

fn writer(req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = httpz.ContentType.JSON;

    const name = req.param("name").?;
    try std.json.Stringify.value(.{
        .name = name
    }, .{ .whitespace = .indent_4 }, res.writer());
}

fn metrics(_: *httpz.Request, res: *httpz.Response) !void {
    // httpz exposes some prometheus-style metrics
    return httpz.writeMetrics(res.writer());
}

fn formShow(_: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\ <html>
        \\ <form method=post>
        \\    <p><input name=name value=goku></p>
        \\    <p><input name=power value=9001></p>
        \\    <p><input type=submit value=submit></p>
        \\ </form>
    ;
}

fn formPost(req: *httpz.Request, res: *httpz.Response) !void {
    var it = (try req.formData()).iterator();

    res.content_type = .TEXT;

    var w = res.writer();
    while (it.next()) |kv| {
        try w.print("{s}={s}\n", .{ kv.key, kv.value });
    }
}

fn explicitWrite(_: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\ There may be cases where your response is tied to data which
        \\ required cleanup. If `res.arena` and `res.writer()` can't solve
        \\ the issue, you can always call `res.write()` explicitly
    ;
    return res.write();
}
