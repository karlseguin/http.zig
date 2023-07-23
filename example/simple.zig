const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

var index_file_contents: []u8 = undefined;

pub fn start(allocator: Allocator) !void {
    var server = try httpz.Server().init(allocator, .{ .pool_size = 20 });
    var router = server.router();

    server.notFound(notFound);

    var index_file = try std.fs.cwd().openFile("example/index.html", .{});
    defer index_file.close();
    index_file_contents = try index_file.readToEndAlloc(allocator, 100000);
    defer allocator.free(index_file_contents);

    router.get("/", index);
    router.get("/hello", hello);
    router.get("/json/hello/:name", json);
    router.get("/writer/hello/:name", writer);
    router.get("/chunked_response", chunked);
    router.get("/static_file", staticFile);
    router.get("/cached_static_file", cachedStaticFile);
    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.body =
        \\<!DOCTYPE html>
        \\ <ul>
        \\ <li><a href="/hello?name=Teg">Querystring + text output</a>
        \\ <li><a href="/writer/hello/Ghanima">Path parameter + serialize json object</a>
        \\ <li><a href="/json/hello/Duncan">Path parameter + json writer</a>
        \\ <li><a href="/chunked_response">Chunked response</a>
        \\ <li><a href="/static_file">Static file</a>
        \\ <li><a href="/cached_static_file">Cached static file</a>
        \\ <li><a href="http://localhost:5883/increment">Global shared state</a>
    ;
}

fn hello(req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const name = query.get("name") orelse "stranger";

    // One solution is to use res.arena
    // var out = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
    // res.body = out

    // another is to use res.writer(), which might be more efficient in some cases
    try std.fmt.format(res.writer(), "Hello {s}", .{name});
}

fn json(req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name").?;
    try res.json(.{ .hello = name }, .{});
}

fn writer(req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = httpz.ContentType.JSON;

    const name = req.param("name").?;
    var ws = std.json.writeStream(res.writer(), 4);
    try ws.beginObject();
    try ws.objectField("name");
    try ws.emitString(name);
    try ws.endObject();
}

fn chunked(_: *httpz.Request, res: *httpz.Response) !void {
    // status and headers (including content type) must be set
    // before the first call to chunk
    res.status = 200;
    res.header("A", "Header");
    res.content_type = httpz.ContentType.TEXT;

    try res.chunk("This is a chunk");
    try res.chunk("\r\n");
    try res.chunk("And another one");
}

fn staticFile(req: *httpz.Request, res: *httpz.Response) !void {
    var index_file = try std.fs.cwd().openFile("example/index.html", .{});
    defer index_file.close();
    res.body = try index_file.readToEndAlloc(req.arena, 100000);
}

fn cachedStaticFile(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.body = index_file_contents;
}

fn notFound(_: *httpz.Request, res: *httpz.Response) !void {
    res.status = 404;
    res.body = "Not found";
}
