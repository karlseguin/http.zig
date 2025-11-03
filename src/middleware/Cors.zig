const std = @import("std");
const httpz = @import("../httpz.zig");

pub const Config = struct {
    origin: []const u8,
    headers: ?[]const u8 = null,
    methods: ?[]const u8 = null,
    max_age: ?[]const u8 = null,
    credentials: ?[]const u8 = null,
};

origin: []const u8,
headers: ?[]const u8 = null,
methods: ?[]const u8 = null,
max_age: ?[]const u8 = null,
credentials: ?[]const u8 = null,

const Cors = @This();

pub fn init(config: Config) !Cors {
    return .{
        .origin = config.origin,
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

    var allowed_origins = std.mem.splitSequence(u8, self.origin, ",");
    var includes_origin = false;
    while (allowed_origins.next()) |allowed_origin| {
        const trimmed_origin = std.mem.trim(u8, allowed_origin, " \t");
        if (std.mem.eql(u8, origin, trimmed_origin)) {
            includes_origin = true;
            break;
        }
    }

    if (!includes_origin) {
        return executor.next();
    }

    res.header("Access-Control-Allow-Origin", origin);

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
