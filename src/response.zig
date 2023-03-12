const std = @import("std");

const t = @import("t.zig");

const Headers = @import("headers.zig").Headers;

const Allocator = std.mem.Allocator;

pub const Config = struct {
	max_header_count: usize = 32,
};

// Should not be called directly, but initialized through a pool
pub fn init(allocator: Allocator, config: Config) !*Response {
	var response = try allocator.create(Response);
	response.headers = try Headers.init(allocator, config.max_header_count);
	return response;
}

pub const Response = struct {
	status: u16,
	headers: Headers,

	const Self = @This();

	pub fn deinit(self: *Self) void {
		self.headers.deinit();
	}

	pub fn reset(self: *Self) void {
		self.headers.reset();
	}

	pub fn write(self: Self, comptime S: type, stream: S) !void {
		switch (self.status) {
			100 => try stream.write("HTTP/1.1 100\r\n"),
			101 => try stream.write("HTTP/1.1 101\r\n"),
			102 => try stream.write("HTTP/1.1 102\r\n"),
			103 => try stream.write("HTTP/1.1 103\r\n"),
			200 => try stream.write("HTTP/1.1 200\r\n"),
			201 => try stream.write("HTTP/1.1 201\r\n"),
			202 => try stream.write("HTTP/1.1 202\r\n"),
			203 => try stream.write("HTTP/1.1 203\r\n"),
			204 => try stream.write("HTTP/1.1 204\r\n"),
			205 => try stream.write("HTTP/1.1 205\r\n"),
			206 => try stream.write("HTTP/1.1 206\r\n"),
			207 => try stream.write("HTTP/1.1 207\r\n"),
			208 => try stream.write("HTTP/1.1 208\r\n"),
			226 => try stream.write("HTTP/1.1 226\r\n"),
			300 => try stream.write("HTTP/1.1 300\r\n"),
			301 => try stream.write("HTTP/1.1 301\r\n"),
			302 => try stream.write("HTTP/1.1 302\r\n"),
			303 => try stream.write("HTTP/1.1 303\r\n"),
			304 => try stream.write("HTTP/1.1 304\r\n"),
			305 => try stream.write("HTTP/1.1 305\r\n"),
			306 => try stream.write("HTTP/1.1 306\r\n"),
			307 => try stream.write("HTTP/1.1 307\r\n"),
			308 => try stream.write("HTTP/1.1 308\r\n"),
			400 => try stream.write("HTTP/1.1 400\r\n"),
			401 => try stream.write("HTTP/1.1 401\r\n"),
			402 => try stream.write("HTTP/1.1 402\r\n"),
			403 => try stream.write("HTTP/1.1 403\r\n"),
			404 => try stream.write("HTTP/1.1 404\r\n"),
			405 => try stream.write("HTTP/1.1 405\r\n"),
			406 => try stream.write("HTTP/1.1 406\r\n"),
			407 => try stream.write("HTTP/1.1 407\r\n"),
			408 => try stream.write("HTTP/1.1 408\r\n"),
			409 => try stream.write("HTTP/1.1 409\r\n"),
			410 => try stream.write("HTTP/1.1 410\r\n"),
			411 => try stream.write("HTTP/1.1 411\r\n"),
			412 => try stream.write("HTTP/1.1 412\r\n"),
			413 => try stream.write("HTTP/1.1 413\r\n"),
			414 => try stream.write("HTTP/1.1 414\r\n"),
			415 => try stream.write("HTTP/1.1 415\r\n"),
			416 => try stream.write("HTTP/1.1 416\r\n"),
			417 => try stream.write("HTTP/1.1 417\r\n"),
			418 => try stream.write("HTTP/1.1 418\r\n"),
			421 => try stream.write("HTTP/1.1 421\r\n"),
			422 => try stream.write("HTTP/1.1 422\r\n"),
			423 => try stream.write("HTTP/1.1 423\r\n"),
			424 => try stream.write("HTTP/1.1 424\r\n"),
			425 => try stream.write("HTTP/1.1 425\r\n"),
			426 => try stream.write("HTTP/1.1 426\r\n"),
			428 => try stream.write("HTTP/1.1 428\r\n"),
			429 => try stream.write("HTTP/1.1 429\r\n"),
			431 => try stream.write("HTTP/1.1 431\r\n"),
			451 => try stream.write("HTTP/1.1 451\r\n"),
			500 => try stream.write("HTTP/1.1 500\r\n"),
			501 => try stream.write("HTTP/1.1 501\r\n"),
			502 => try stream.write("HTTP/1.1 502\r\n"),
			503 => try stream.write("HTTP/1.1 503\r\n"),
			504 => try stream.write("HTTP/1.1 504\r\n"),
			505 => try stream.write("HTTP/1.1 505\r\n"),
			506 => try stream.write("HTTP/1.1 506\r\n"),
			507 => try stream.write("HTTP/1.1 507\r\n"),
			508 => try stream.write("HTTP/1.1 508\r\n"),
			510 => try stream.write("HTTP/1.1 510\r\n"),
			511 => try stream.write("HTTP/1.1 511\r\n"),
			else => {
				var buf: [20]u8 = undefined;
				var rl = try std.fmt.bufPrint(&buf, "HTTP/1.1 {d}\r\n", .{self.status});
				try stream.write(rl);
			}
		}
		try stream.write("content-length: 0\r\n");
		try stream.write("\r\n");
	}
};
