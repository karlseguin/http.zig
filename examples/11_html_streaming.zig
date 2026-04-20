const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const PORT = 8801;

/// This example demonstrates HTML streaming.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var server = try httpz.Server(void).init(init.io, allocator, .{
        .address = .localhost(PORT),
    }, {});
    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = try server.router(.{});

    router.get("/", index, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {

    try res.chunk(
        \\<!DOCTYPE html>
        \\<html>
        \\  <body>
        \\      <template shadowrootmode="open">
        \\          <ul>
        \\              <li><slot name="item-0">Loading...</slot></li>
        \\              <li><slot name="item-1">Loading...</slot></li>
        \\              <li><slot name="item-2">Loading...</slot></li>
        \\          </ul>
        \\      </template>
        \\  </body>
        \\</html>
    );

    const io = res.conn.io;
    try io.sleep(.fromSeconds(1), .awake);
    try res.chunk("\n<span slot='item-2'>Item 2</span>");
    try io.sleep(.fromSeconds(1), .awake);
    try res.chunk("\n<span slot='item-0'>Item 0</span>");
    try io.sleep(.fromSeconds(1), .awake);
    try res.chunk("\n<span slot='item-1'>Item 1</span>");
}
