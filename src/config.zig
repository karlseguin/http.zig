const request = @import("request.zig");

pub const Config = struct {
	port: ?u16 = null,
	address: ?[]const u8 = null,
	request: request.Config = request.Config{},
};
