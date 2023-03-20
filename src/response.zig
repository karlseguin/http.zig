const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
const httpz = @import("httpz.zig");
const KeyValue = @import("key_value.zig").KeyValue;

const mem = std.mem;
const Allocator = std.mem.Allocator;
const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;

pub const Config = struct {
	max_header_count: usize = 16,
	buffer_size: usize = 4096,
};

pub const Response = struct {
	// The body to write, if any
	body: ?[]const u8,

	// The status code to write.
	status: u16,

	// The response headers.
	// Using res.header(NAME, VALUE) is preferred.
	headers: KeyValue,

	// The content type. Use header("content-type", value) for a content type
	// which isn't available in the httpz.ContentType enum.
	content_type: ?httpz.ContentType,

	// A buffer that exists for the entire lifetime of the response. As we piece
	// our header together (e.g. looping through the headers to create NAME: value\r\n)
	// we buffer it in here to limit the # of calls we make to stream.write
	static: []u8,

	// An arena that will be reset at the end of each request. Can be used
	// internally by this framework. The application is also free to make use of
	// this arena. This is the same arena as request.arena.
	arena: Allocator,

	const Self = @This();

	// Should not be called directly, but initialized through a pool
	pub fn init(self: *Self, allocator: Allocator, arena: Allocator, config: Config) !void {
		self.arena = arena;
		self.body = null;
		self.status = 200;
		self.content_type = null;
		self.static = try allocator.alloc(u8, config.buffer_size);
		self.headers = try KeyValue.init(allocator, config.max_header_count);
	}

	pub fn deinit(self: *Self, allocator: Allocator) void {
		self.headers.deinit();
		allocator.free(self.static);
	}

	pub fn reset(self: *Self) void {
		self.body = null;
		self.status = 200;
		self.content_type = null;
		self.headers.reset();
	}

	pub fn setBody(self: *Self, value: []const u8) void {
		self.body = value;
	}

	pub fn header(self: *Self, name: []const u8, value: []const u8) void {
		self.headers.add(name, value);
	}

	pub fn write(self: Self, stream: Stream) !void {
		var buf = self.static;
		var pos: usize = 14; // "HTTP/1.1 XXX\r\n".len

		switch (self.status) {
			100 => mem.copy(u8, buf, "HTTP/1.1 100\r\n"),
			101 => mem.copy(u8, buf, "HTTP/1.1 101\r\n"),
			102 => mem.copy(u8, buf, "HTTP/1.1 102\r\n"),
			103 => mem.copy(u8, buf, "HTTP/1.1 103\r\n"),
			200 => mem.copy(u8, buf, "HTTP/1.1 200\r\n"),
			201 => mem.copy(u8, buf, "HTTP/1.1 201\r\n"),
			202 => mem.copy(u8, buf, "HTTP/1.1 202\r\n"),
			203 => mem.copy(u8, buf, "HTTP/1.1 203\r\n"),
			204 => mem.copy(u8, buf, "HTTP/1.1 204\r\n"),
			205 => mem.copy(u8, buf, "HTTP/1.1 205\r\n"),
			206 => mem.copy(u8, buf, "HTTP/1.1 206\r\n"),
			207 => mem.copy(u8, buf, "HTTP/1.1 207\r\n"),
			208 => mem.copy(u8, buf, "HTTP/1.1 208\r\n"),
			226 => mem.copy(u8, buf, "HTTP/1.1 226\r\n"),
			300 => mem.copy(u8, buf, "HTTP/1.1 300\r\n"),
			301 => mem.copy(u8, buf, "HTTP/1.1 301\r\n"),
			302 => mem.copy(u8, buf, "HTTP/1.1 302\r\n"),
			303 => mem.copy(u8, buf, "HTTP/1.1 303\r\n"),
			304 => mem.copy(u8, buf, "HTTP/1.1 304\r\n"),
			305 => mem.copy(u8, buf, "HTTP/1.1 305\r\n"),
			306 => mem.copy(u8, buf, "HTTP/1.1 306\r\n"),
			307 => mem.copy(u8, buf, "HTTP/1.1 307\r\n"),
			308 => mem.copy(u8, buf, "HTTP/1.1 308\r\n"),
			400 => mem.copy(u8, buf, "HTTP/1.1 400\r\n"),
			401 => mem.copy(u8, buf, "HTTP/1.1 401\r\n"),
			402 => mem.copy(u8, buf, "HTTP/1.1 402\r\n"),
			403 => mem.copy(u8, buf, "HTTP/1.1 403\r\n"),
			404 => mem.copy(u8, buf, "HTTP/1.1 404\r\n"),
			405 => mem.copy(u8, buf, "HTTP/1.1 405\r\n"),
			406 => mem.copy(u8, buf, "HTTP/1.1 406\r\n"),
			407 => mem.copy(u8, buf, "HTTP/1.1 407\r\n"),
			408 => mem.copy(u8, buf, "HTTP/1.1 408\r\n"),
			409 => mem.copy(u8, buf, "HTTP/1.1 409\r\n"),
			410 => mem.copy(u8, buf, "HTTP/1.1 410\r\n"),
			411 => mem.copy(u8, buf, "HTTP/1.1 411\r\n"),
			412 => mem.copy(u8, buf, "HTTP/1.1 412\r\n"),
			413 => mem.copy(u8, buf, "HTTP/1.1 413\r\n"),
			414 => mem.copy(u8, buf, "HTTP/1.1 414\r\n"),
			415 => mem.copy(u8, buf, "HTTP/1.1 415\r\n"),
			416 => mem.copy(u8, buf, "HTTP/1.1 416\r\n"),
			417 => mem.copy(u8, buf, "HTTP/1.1 417\r\n"),
			418 => mem.copy(u8, buf, "HTTP/1.1 418\r\n"),
			421 => mem.copy(u8, buf, "HTTP/1.1 421\r\n"),
			422 => mem.copy(u8, buf, "HTTP/1.1 422\r\n"),
			423 => mem.copy(u8, buf, "HTTP/1.1 423\r\n"),
			424 => mem.copy(u8, buf, "HTTP/1.1 424\r\n"),
			425 => mem.copy(u8, buf, "HTTP/1.1 425\r\n"),
			426 => mem.copy(u8, buf, "HTTP/1.1 426\r\n"),
			428 => mem.copy(u8, buf, "HTTP/1.1 428\r\n"),
			429 => mem.copy(u8, buf, "HTTP/1.1 429\r\n"),
			431 => mem.copy(u8, buf, "HTTP/1.1 431\r\n"),
			451 => mem.copy(u8, buf, "HTTP/1.1 451\r\n"),
			500 => mem.copy(u8, buf, "HTTP/1.1 500\r\n"),
			501 => mem.copy(u8, buf, "HTTP/1.1 501\r\n"),
			502 => mem.copy(u8, buf, "HTTP/1.1 502\r\n"),
			503 => mem.copy(u8, buf, "HTTP/1.1 503\r\n"),
			504 => mem.copy(u8, buf, "HTTP/1.1 504\r\n"),
			505 => mem.copy(u8, buf, "HTTP/1.1 505\r\n"),
			506 => mem.copy(u8, buf, "HTTP/1.1 506\r\n"),
			507 => mem.copy(u8, buf, "HTTP/1.1 507\r\n"),
			508 => mem.copy(u8, buf, "HTTP/1.1 508\r\n"),
			510 => mem.copy(u8, buf, "HTTP/1.1 510\r\n"),
			511 => mem.copy(u8, buf, "HTTP/1.1 511\r\n"),
			else => |s| {
				mem.copy(u8, buf, "HTTP/1.1 ");
				// "HTTP/1.1 ".len == 9
				pos = 9 + writeInt(buf[9..], @as(u32, s));
				buf[pos] = '\r';
				buf[pos+1] = '\n';
				pos += 2;
			}
		}

		if (self.content_type) |ct| {
			const content_type = switch (ct) {
				.BINARY => "Content-Type: application/octet-stream\r\n",
				.CSS => "Content-Type: text/css\r\n",
				.CSV => "Content-Type: text/csv\r\n",
				.GIF => "Content-Type: image/gif\r\n",
				.GZ => "Content-Type: application/gzip\r\n",
				.HTML => "Content-Type: text/html\r\n",
				.ICO => "Content-Type: image/vnd.microsoft.icon\r\n",
				.JPG => "Content-Type: image/jpeg\r\n",
				.JS => "Content-Type: application/javascript\r\n",
				.JSON => "Content-Type: application/json\r\n",
				.PDF => "Content-Type: application/pdf\r\n",
				.PNG => "Content-Type: image/png\r\n",
				.SVG => "Content-Type: image/svg+xml\r\n",
				.TAR => "Content-Type: application/x-tar\r\n",
				.TEXT => "Content-Type: text/plain\r\n",
				.WEBP => "Content-Type: image/webp\r\n",
				.XML => "Content-Type: application/xml\r\n",
			};
			mem.copy(u8, buf[pos..], content_type);
			pos += content_type.len;
		}

		{
			const headers = &self.headers;
			const header_count = headers.len;
			const names = headers.keys[0..header_count];
			const values = headers.values[0..header_count];
			for (names, values) |name, value| {
				// 4 for the colon + space between the name and value
				// and the trailing \r\n
				const header_line_length = name.len + value.len + 4;
				if (buf.len < pos + header_line_length) {
					try stream.writeAll(buf[0..pos]);
					pos = 0;
				}
				mem.copy(u8, buf[pos..], name);
				pos += name.len;
				buf[pos] = ':';
				buf[pos+1] = ' ';
				pos += 2;

				mem.copy(u8, buf[pos..], value);
				pos += value.len;
				buf[pos] = '\r';
				buf[pos+1] = '\n';
				pos += 2;
			}
		}

		if (self.body) |b| {
			if (buf.len < pos + 32) {
				try stream.writeAll(buf[0..pos]);
				pos = 0;
			}
			mem.copy(u8, buf[pos..], "Content-Length: ");
			pos += 16;
			pos += writeInt(buf[pos..], @intCast(u32, b.len));
			buf[pos] = '\r';
			buf[pos+1] = '\n';
			buf[pos+2] = '\r';
			buf[pos+3] = '\n';
			try stream.writeAll(buf[0..(pos+4)]);

			try stream.writeAll(b);
		} else {
			const fin = "Content-Length: 0\r\n\r\n";
			const final_pos = pos + fin.len;
			if (pos == 0) {
				try stream.writeAll(fin);
			} else if (buf.len < final_pos) {
				try stream.writeAll(buf[0..pos]);
				try stream.writeAll(fin);
			} else {
				mem.copy(u8, buf[pos..], fin);
				try stream.writeAll(buf[0..final_pos]);
			}
		}
	}
};

fn writeInt(into: []u8, n: u32) usize {
	if (n == 0) {
		into[0] = '0';
		return 1;
	}

	var num = n;
	var i: usize = 0;
	while (num != 0) : (i += 1) {
		const rem = num % 10;
		into[i] = @intCast(u8, rem) + '0';
		num = num / 10;
	}
	const a = into[0..i];
	std.mem.reverse(u8, a);
	return i;
}

test "writeInt" {
	var buf: [10]u8 = undefined;
	var tst: [10]u8 = undefined;
	for (0..100_009) |i| {
		const expected_len = std.fmt.formatIntBuf(tst[0..], i, 10, .lower, .{});
		const l = writeInt(&buf, @intCast(u32, i));
		try t.expectString(tst[0..expected_len], buf[0..l]);
	}
}

test "response: write" {
	var s = t.Stream.init();
	var res = testResponse(.{});
	defer testCleanup(res, s);

	{
		// no body
		res.status = 401;
		try res.write(s);
		try t.expectString("HTTP/1.1 401\r\nContent-Length: 0\r\n\r\n", s.received.items);
	}

	{
		// body
		s.reset(); res.reset();
		res.status = 200;
		res.setBody("hello");
		try res.write(s);
		try t.expectString("HTTP/1.1 200\r\nContent-Length: 5\r\n\r\nhello", s.received.items);
	}
}

test "response: content_type" {
	var s = t.Stream.init();
	var res = testResponse(.{});
	defer testCleanup(res, s);

	{
		res.content_type = httpz.ContentType.WEBP;
		try res.write(s);
		try t.expectString("HTTP/1.1 200\r\nContent-Type: image/webp\r\nContent-Length: 0\r\n\r\n", s.received.items);
	}
}

test "response: write static sizes" {
	{
		// no header or bodys
		// 19 is the length of our longest header line
		for (19..40) |i| {
			var s = t.Stream.init();
			var res = testResponse(.{.buffer_size = i});
			defer testCleanup(res, s);

			res.status = 792;
			try res.write(s);
			try t.expectString("HTTP/1.1 792\r\nContent-Length: 0\r\n\r\n", s.received.items);
		}
	}

	{
		// no body
		// 19 is the length of our longest header line
		for (19..110) |i| {
			var s = t.Stream.init();
			var res = testResponse(.{.buffer_size = i});
			defer testCleanup(res, s);

			res.status = 401;
			res.header("a-header", "a-value");
			res.header("b-hdr", "b-val");
			res.header("c-header11", "cv");
			try res.write(s);
			try t.expectString("HTTP/1.1 401\r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 0\r\n\r\n", s.received.items);
		}
	}

	{
		// 22 is the length of our longest header line (the content-length)
		for (22..110) |i| {
			var s = t.Stream.init();
			var res = testResponse(.{.buffer_size = i});
			defer testCleanup(res, s);

			res.status = 8;
			res.header("a-header", "a-value");
			res.header("b-hdr", "b-val");
			res.header("c-header11", "cv");
			res.setBody("hello world!");
			try res.write(s);
			try t.expectString("HTTP/1.1 8\r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 12\r\n\r\nhello world!", s.received.items);
		}
	}
}

fn testResponse(config: Config) *Response {
	var res = t.allocator.create(Response) catch unreachable;
	res.init(t.allocator, t.allocator, config) catch unreachable;
	return res;
}

fn testCleanup(r: *Response, s: *t.Stream) void {
	r.deinit(t.allocator);
	t.allocator.destroy(r);
	defer s.deinit();
}
