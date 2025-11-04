const std = @import("std");
const httpz = @import("../httpz.zig");

pub const Origin = union(enum) {
    wildcard,
    list: []const []const u8,
};

pub const Config = struct {
    origin: []const u8,
    headers: ?[]const u8 = null,
    methods: ?[]const u8 = null,
    max_age: ?[]const u8 = null,
    credentials: ?[]const u8 = null,
};

origin: Origin,
headers: ?[]const u8 = null,
methods: ?[]const u8 = null,
max_age: ?[]const u8 = null,
credentials: ?[]const u8 = null,

const Cors = @This();

pub fn init(config: Config, mw_config: httpz.MiddlewareConfig) !Cors {
    const origin = try parseOrigin(config.origin, mw_config.arena);

    return .{
        .origin = origin,
        .headers = config.headers,
        .methods = config.methods,
        .max_age = config.max_age,
        .credentials = config.credentials,
    };
}

pub fn execute(self: *const Cors, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    const origin = req.header("origin") orelse {
        return executor.next();
    };

    const includes_origin = switch (self.origin) {
        .wildcard => true,
        .list => |allowed_origins| blk: {
            for (allowed_origins) |allowed_origin| {
                if (std.mem.eql(u8, origin, allowed_origin)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
    };

    if (!includes_origin) {
        return executor.next();
    }

    switch (self.origin) {
        .wildcard => res.header("Access-Control-Allow-Origin", "*"),
        .list => res.header("Access-Control-Allow-Origin", origin),
    }

    if (self.credentials) |credentials| {
        res.header("Access-Control-Allow-Credentials", credentials);
    }

    if (req.method != .OPTIONS) {
        return executor.next();
    }

    const mode = req.header("sec-fetch-mode") orelse {
        return executor.next();
    };

    if (std.mem.eql(u8, mode, "cors") == false) {
        return executor.next();
    }

    if (self.headers) |headers| {
        res.header("Access-Control-Allow-Headers", headers);
    }
    if (self.methods) |methods| {
        res.header("Access-Control-Allow-Methods", methods);
    }
    if (self.max_age) |max_age| {
        res.header("Access-Control-Max-Age", max_age);
    }

    res.status = 204;
}

fn parseOrigin(origin_str: []const u8, arena: std.mem.Allocator) !Origin {
    const trimmed = std.mem.trim(u8, origin_str, " \t");

    // Check for wildcard
    if (std.mem.eql(u8, trimmed, "*")) {
        return .wildcard;
    }

    // Check if it contains commas (multiple origins)
    if (std.mem.indexOf(u8, trimmed, ",")) |_| {
        // Count how many origins we have
        var count: usize = 0;
        var it = std.mem.splitSequence(u8, trimmed, ",");
        while (it.next()) |_| {
            count += 1;
        }

        // Allocate array for origins
        const origins = try arena.alloc([]const u8, count);

        // Parse and trim each origin
        it.reset();
        var i: usize = 0;
        while (it.next()) |origin| : (i += 1) {
            origins[i] = std.mem.trim(u8, origin, " \t");
        }

        return .{ .list = origins };
    }

    // Single origin
    const single_origin = try arena.alloc([]const u8, 1);
    single_origin[0] = trimmed;
    return .{ .list = single_origin };
}
