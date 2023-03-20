const httpz = @import("httpz.zig");
const server = @import("server.zig");
const request = @import("request.zig");
const response = @import("response.zig");

pub const Config = struct {
	port: ?u16 = null,
	pool_size: u16 = 100,
	address: ?[]const u8 = null,
	request: request.Config = request.Config{},
	response: response.Config = response.Config{},
	errorHandler: httpz.ActionError = server.errorHandler,
};
