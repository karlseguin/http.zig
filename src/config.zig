const request = @import("request.zig");
const response = @import("response.zig");

pub const Config = struct {
	// done like this so that an external app can access it as
	// httpz.Config.Request or httpz.Config.Response
	pub const Request = request.Config;
	pub const Response = response.Config;

	port: ?u16 = null,
	address: ?[]const u8 = null,
	unix_path: ?[]const u8 = null,
	workers: Worker = .{},
	request: Request = .{},
	response: Response = .{},
	keepalive: Keepalive = .{},
	cors: ?CORS = null,

	pub const CORS = struct {
		origin: []const u8,
		headers: ?[]const u8 = null,
		methods: ?[]const u8 = null,
		max_age: ?[]const u8 = null,
	};

	pub const Worker = struct {
		count: ?usize = null,
		max_conn: ?u16 = null,
		min_conn: ?u16 = null,
	};

	pub const Keepalive = struct {
		timeout: ?u32 = null,
	};
};
