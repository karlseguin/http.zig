const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const PORT = 8801;

/// This example demonstrates HTML streaming.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try httpz.Server(void).init(allocator, .{
        .port = PORT,
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
    const wait_time = 1_000_000_000; // 1 second

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
    std.Thread.sleep(wait_time);
    try res.chunk("\n<span slot='item-2'>Item 2</span>");
    std.Thread.sleep(wait_time);
    try res.chunk("\n<span slot='item-0'>Item 0</span>");
    std.Thread.sleep(wait_time);
    try res.chunk("\n<span slot='item-1'>Item 1</span>");
}
