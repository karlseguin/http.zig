const pool = @import("pool.zig");
const request = @import("request.zig");
const response = @import("response.zig");

pub const Config = struct {
	// done like this so that an external app can access it as
	// httpz.Config.Request or httpz.Config.Response
	pub const Pool = pool.Config;
	pub const Request = request.Config;
	pub const Response = response.Config;

	port: ?u16 = null,
	address: ?[]const u8 = null,
	pool: Pool = Pool{},
	thread_pool: u32 = 0,
	request: Request = Request{},
	response: Response = Response{},
	cors: ?CORS = null,

	pub const CORS = struct {
		origin: []const u8,
		headers: ?[]const u8 = null,
		methods: ?[]const u8 = null,
		max_age: ?[]const u8 = null,
	};
};
