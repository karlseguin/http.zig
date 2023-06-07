const request = @import("request.zig");
const response = @import("response.zig");

pub const Config = struct {
	port: ?u16 = null,
	pool_size: ?u16 = null,
	address: ?[]const u8 = null,
	request: request.Config = request.Config{},
	response: response.Config = response.Config{},
	cors: ?CORS = null,

	const CORS = struct {
		origin: []const u8,
		headers: ?[]const u8 = null,
		methods: ?[]const u8 = null,
		max_age: ?[]const u8 = null,
	};
};
