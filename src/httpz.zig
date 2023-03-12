const std = @import("std");

pub const server = @import("server.zig");
const Stream = @import("stream.zig").Stream;
pub const Config = @import("config.zig").Config;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;

const Allocator = std.mem.Allocator;

pub const Server = server.Server;

pub fn listen(allocator: Allocator, config: Config) !void {
	const handler = server.Handler{};
	var s = try Server(server.Handler).init(allocator, handler, config);
	try s.listen();
}

pub const Protocol = enum {
	HTTP10,
	HTTP11,
};

pub const Method = enum {
	GET,
	HEAD,
	POST,
	PUT,
	PATCH,
	DELETE,
	OPTIONS,
};


test {
	//_ = @import("server.zig");
	std.testing.refAllDecls(@This());
}
