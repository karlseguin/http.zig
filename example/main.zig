const std = @import("std");

const simple = @import("simple.zig");
const global = @import("global.zig");
const dispatcher = @import("dispatcher.zig");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // This example starts 3 separate servers, each listening on a different
    // port.

    // This first server, listening on 127.0.0.1:5882, is a simple server. It
    // best showcases the *http.Request and *http.Response APIs
    const t1 = try std.Thread.spawn(.{}, simple.start, .{allocator});

    // This second server, listening on 127.0.0.1:5883, has a global shared context.
    // It showcases how global data can be access from HTTP actions;
    const t2 = try std.Thread.spawn(.{}, global.start, .{allocator});

    // This third server, listening on 127.0.0.1:5884, has a global shared context
    // with a per-request context tied together using a custom dispatcher.
    const t3 = try std.Thread.spawn(.{}, dispatcher.start, .{allocator});

    std.log.info("Three demo servers have been started. Please load http://127.0.0.1:5882", .{});

    t1.join();
    t2.join();
    t3.join();
}
