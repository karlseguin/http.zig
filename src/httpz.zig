const std = @import("std");

const Stream = @import("stream.zig").Stream;
pub const Server = @import("server.zig").Server;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;

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
	std.testing.refAllDeclsRecursive(@This());
}
