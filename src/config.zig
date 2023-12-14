const request = @import("request.zig");
const response = @import("response.zig");

pub const Config = struct {
	port: ?u16 = null,
	address: ?[]const u8 = null,
	unix_path: ?[]const u8 = null,
	workers: Worker = .{},
	request: Request = .{},
	response: Response = .{},
	timeout: Timeout = .{},
	cors: ?CORS = null,
	websocket: ?Websocket = null,

	pub const Worker = struct {
		count: ?u16 = null,
		max_conn: ?u16 = null,
		min_conn: ?u16 = null,
		large_buffer_count: ?u16 = null,
		large_buffer_size: ?u32 = null,
	};

	pub const Request = struct {
		max_body_size: ?usize = null,
		buffer_size: ?usize = null,
		max_header_count: ?usize = null,
		max_param_count: ?usize = null,
		max_query_count: ?usize = null,
	};

	pub const Response = struct {
		max_header_count: ?usize = null,
		body_buffer_size: ?usize = null,
		header_buffer_size: ?usize = null,
	};

	pub const Timeout = struct {
		request: ?u32 = null,
		keepalive: ?u32 = null,
		request_count: ?u32 = null,
	};

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
