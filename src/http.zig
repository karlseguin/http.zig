const std = @import("std");

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
	_ = @import("./server.zig");
	// _ = @import("./pool.zig");
	std.testing.refAllDeclsRecursive(@This());
}
