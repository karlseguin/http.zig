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
	unix_path: ?[]const u8 = null,
	pool: Pool = Pool{},
	thread_pool: u32 = 0,
	request: Request = Request{},
	response: Response = Response{},
	cors: ?CORS = null,
	websocket: ?Websocket = null,

	pub const CORS = struct {
		origin: []const u8,
		headers: ?[]const u8 = null,
		methods: ?[]const u8 = null,
		max_age: ?[]const u8 = null,
	};

	pub const Websocket = struct {
		max_size: usize = 65536,
		buffer_size: usize = 4096,
		handle_ping: bool = false,
		handle_pong: bool = false,
		handle_close: bool = false,
		large_buffer_pool_count: u16 = 8,
		large_buffer_size: usize = 32768,
	};
};
