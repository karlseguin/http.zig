const std = @import("std");

const t = @import("t.zig");

const KeyValue = @import("key_value.zig").KeyValue;

const Allocator = std.mem.Allocator;

pub const Config = struct {
	max_header_count: usize = 10,
};

// Should not be called directly, but initialized through a pool
pub fn init(allocator: Allocator, config: Config) !*Response {
	var response = try allocator.create(Response);
	response.body = null;
	response.headers = try KeyValue.init(allocator, config.max_header_count);
	return response;
}

pub const Response = struct {
	body: ?[]const u8,
	status: u16,
	scrap: [10]u8, // enough to hold an atoi of a large positive numbr
	headers: KeyValue,

	const Self = @This();

	pub fn deinit(self: *Self) void {
		self.headers.deinit();
	}

	pub fn reset(self: *Self) void {
		self.body = null;
		self.headers.reset();
	}
	pub fn text(self: *Self, value: []const u8) void {
		self.body = value;
	}

	pub fn write(self: Self, comptime S: type, stream: S) !void {
		var scrap = self.scrap;
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
			else => |s| {
				try stream.write("HTTP/1.1 ");
				try stream.write(itoa(@as(u32, s), scrap[0..]));
				try stream.write("\r\n");
			}
		}
		if (self.body) |b| {
			try stream.write("Content-Length: ");
			try stream.write(itoa(@intCast(u32, b.len), scrap[0..]));
			try stream.write("\r\n\r\n");
			try stream.write(b);
		} else {
			try stream.write("Content-Length: 0\r\n\r\n");
		}
	}
};

fn itoa(n: u32, buf: []u8) []u8 {
	if (n == 0) {
		buf[0] = '0';
		return buf[0..1];
	}

	var num = n;
	var i: usize = 0;
	while (num != 0) : (i += 1) {
		const rem = num % 10;
		buf[i] = @intCast(u8, rem) + '0';
		num = num / 10;
	}
	const a = buf[0..i];
	std.mem.reverse(u8, a);
	return a;
}

test "atoi" {
	var buf: [10]u8 = undefined;
	var tst: [10]u8 = undefined;
	for (0..100_009) |i| {
		const expected_len = std.fmt.formatIntBuf(tst[0..], i, 10, .lower, .{});
		try t.expectString(tst[0..expected_len], itoa(@intCast(u32, i), &buf));
	}
}

test "response: write" {
	var s = t.Stream.init();
	var res = try init(t.allocator, .{});
	defer cleanupWrite(res, &s);

	{
		// no body
		res.status = 401;
		try res.write(*t.Stream, &s);
		try t.expectString("HTTP/1.1 401\r\nContent-Length: 0\r\n\r\n", s.received.items);
	}

	{
		// body
		s.reset(); res.reset();
		res.status = 200;
		res.text("hello");
		try res.write(*t.Stream, &s);
		try t.expectString("HTTP/1.1 200\r\nContent-Length: 5\r\n\r\nhello", s.received.items);
	}
}

fn cleanupWrite(r: *Response, s: *t.Stream) void {
	r.deinit();
	t.allocator.destroy(r);

	defer s.deinit();
}
