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
	body_buffer_size: usize = 32_768,
	header_buffer_size: usize = 4096,
};

pub const Response = struct {
	// Where in body we're writing to. Used for dynamically writes to body, e.g.
	// via the json() or writer() functions
	pos: usize,

	// An explicit body to send
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
	header_buffer: []u8,

	// When possible (when it fits), we'll buffer the body into this static buffer,
	// which exists for the entire lifetime of the response. If the response doesn't
	// fit, we'll allocate the necessary space using the arena allocator.
	body_buffer: []u8,

	// This is either a referene to body_buffer, or a dynamically allocated
	// buffer (in our arena). Used by our writer.
	writer_buffer: []u8,

	// An arena that will be reset at the end of each request. Can be used
	// internally by this framework. The application is also free to make use of
	// this arena. This is the same arena as request.arena.
	arena: Allocator,

	const Self = @This();

	// Should not be called directly, but initialized through a pool
	pub fn init(self: *Self, allocator: Allocator, arena: Allocator, config: Config) !void {
		self.arena = arena;
		self.headers = try KeyValue.init(allocator, config.max_header_count);
		self.body_buffer = try allocator.alloc(u8, config.body_buffer_size);
		self.header_buffer = try allocator.alloc(u8, config.header_buffer_size);
		self.reset();
	}

	pub fn deinit(self: *Self, allocator: Allocator) void {
		self.headers.deinit(allocator);
		allocator.free(self.body_buffer);
		allocator.free(self.header_buffer);
	}

	pub fn reset(self: *Self) void {
		self.pos = 0;
		self.body = null;
		self.status = 200;
		self.content_type = null;
		self.writer_buffer = self.body_buffer;
		self.headers.reset();
	}

	pub fn json(self: *Self, value: anytype) !void {
		const json_options = .{.string = .{.String = .{.escape_solidus = false}}};
		try std.json.stringify(value, json_options, Writer.init(self));
		self.content_type = httpz.ContentType.JSON;
	}

	pub fn header(self: *Self, name: []const u8, value: []const u8) void {
		self.headers.add(name, value);
	}

	pub fn write(self: *Self, stream: Stream) !void {
		var header_pos: usize = 14; // "HTTP/1.1 XXX\r\n".len
		var header_buffer = self.header_buffer;

		switch (self.status) {
			100 => mem.copy(u8, header_buffer, "HTTP/1.1 100\r\n"),
			101 => mem.copy(u8, header_buffer, "HTTP/1.1 101\r\n"),
			102 => mem.copy(u8, header_buffer, "HTTP/1.1 102\r\n"),
			103 => mem.copy(u8, header_buffer, "HTTP/1.1 103\r\n"),
			200 => mem.copy(u8, header_buffer, "HTTP/1.1 200\r\n"),
			201 => mem.copy(u8, header_buffer, "HTTP/1.1 201\r\n"),
			202 => mem.copy(u8, header_buffer, "HTTP/1.1 202\r\n"),
			203 => mem.copy(u8, header_buffer, "HTTP/1.1 203\r\n"),
			204 => mem.copy(u8, header_buffer, "HTTP/1.1 204\r\n"),
			205 => mem.copy(u8, header_buffer, "HTTP/1.1 205\r\n"),
			206 => mem.copy(u8, header_buffer, "HTTP/1.1 206\r\n"),
			207 => mem.copy(u8, header_buffer, "HTTP/1.1 207\r\n"),
			208 => mem.copy(u8, header_buffer, "HTTP/1.1 208\r\n"),
			226 => mem.copy(u8, header_buffer, "HTTP/1.1 226\r\n"),
			300 => mem.copy(u8, header_buffer, "HTTP/1.1 300\r\n"),
			301 => mem.copy(u8, header_buffer, "HTTP/1.1 301\r\n"),
			302 => mem.copy(u8, header_buffer, "HTTP/1.1 302\r\n"),
			303 => mem.copy(u8, header_buffer, "HTTP/1.1 303\r\n"),
			304 => mem.copy(u8, header_buffer, "HTTP/1.1 304\r\n"),
			305 => mem.copy(u8, header_buffer, "HTTP/1.1 305\r\n"),
			306 => mem.copy(u8, header_buffer, "HTTP/1.1 306\r\n"),
			307 => mem.copy(u8, header_buffer, "HTTP/1.1 307\r\n"),
			308 => mem.copy(u8, header_buffer, "HTTP/1.1 308\r\n"),
			400 => mem.copy(u8, header_buffer, "HTTP/1.1 400\r\n"),
			401 => mem.copy(u8, header_buffer, "HTTP/1.1 401\r\n"),
			402 => mem.copy(u8, header_buffer, "HTTP/1.1 402\r\n"),
			403 => mem.copy(u8, header_buffer, "HTTP/1.1 403\r\n"),
			404 => mem.copy(u8, header_buffer, "HTTP/1.1 404\r\n"),
			405 => mem.copy(u8, header_buffer, "HTTP/1.1 405\r\n"),
			406 => mem.copy(u8, header_buffer, "HTTP/1.1 406\r\n"),
			407 => mem.copy(u8, header_buffer, "HTTP/1.1 407\r\n"),
			408 => mem.copy(u8, header_buffer, "HTTP/1.1 408\r\n"),
			409 => mem.copy(u8, header_buffer, "HTTP/1.1 409\r\n"),
			410 => mem.copy(u8, header_buffer, "HTTP/1.1 410\r\n"),
			411 => mem.copy(u8, header_buffer, "HTTP/1.1 411\r\n"),
			412 => mem.copy(u8, header_buffer, "HTTP/1.1 412\r\n"),
			413 => mem.copy(u8, header_buffer, "HTTP/1.1 413\r\n"),
			414 => mem.copy(u8, header_buffer, "HTTP/1.1 414\r\n"),
			415 => mem.copy(u8, header_buffer, "HTTP/1.1 415\r\n"),
			416 => mem.copy(u8, header_buffer, "HTTP/1.1 416\r\n"),
			417 => mem.copy(u8, header_buffer, "HTTP/1.1 417\r\n"),
			418 => mem.copy(u8, header_buffer, "HTTP/1.1 418\r\n"),
			421 => mem.copy(u8, header_buffer, "HTTP/1.1 421\r\n"),
			422 => mem.copy(u8, header_buffer, "HTTP/1.1 422\r\n"),
			423 => mem.copy(u8, header_buffer, "HTTP/1.1 423\r\n"),
			424 => mem.copy(u8, header_buffer, "HTTP/1.1 424\r\n"),
			425 => mem.copy(u8, header_buffer, "HTTP/1.1 425\r\n"),
			426 => mem.copy(u8, header_buffer, "HTTP/1.1 426\r\n"),
			428 => mem.copy(u8, header_buffer, "HTTP/1.1 428\r\n"),
			429 => mem.copy(u8, header_buffer, "HTTP/1.1 429\r\n"),
			431 => mem.copy(u8, header_buffer, "HTTP/1.1 431\r\n"),
			451 => mem.copy(u8, header_buffer, "HTTP/1.1 451\r\n"),
			500 => mem.copy(u8, header_buffer, "HTTP/1.1 500\r\n"),
			501 => mem.copy(u8, header_buffer, "HTTP/1.1 501\r\n"),
			502 => mem.copy(u8, header_buffer, "HTTP/1.1 502\r\n"),
			503 => mem.copy(u8, header_buffer, "HTTP/1.1 503\r\n"),
			504 => mem.copy(u8, header_buffer, "HTTP/1.1 504\r\n"),
			505 => mem.copy(u8, header_buffer, "HTTP/1.1 505\r\n"),
			506 => mem.copy(u8, header_buffer, "HTTP/1.1 506\r\n"),
			507 => mem.copy(u8, header_buffer, "HTTP/1.1 507\r\n"),
			508 => mem.copy(u8, header_buffer, "HTTP/1.1 508\r\n"),
			510 => mem.copy(u8, header_buffer, "HTTP/1.1 510\r\n"),
			511 => mem.copy(u8, header_buffer, "HTTP/1.1 511\r\n"),
			else => |s| {
				mem.copy(u8, header_buffer, "HTTP/1.1 ");
				// "HTTP/1.1 ".len == 9
				header_pos = 9 + writeInt(header_buffer[9..], @as(u32, s));
				header_buffer[header_pos] = '\r';
				header_buffer[header_pos+1] = '\n';
				header_pos += 2;
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
			mem.copy(u8, header_buffer[header_pos..], content_type);
			header_pos += content_type.len;
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
				if (header_buffer.len < header_pos + header_line_length) {
					try stream.writeAll(header_buffer[0..header_pos]);
					header_pos = 0;
				}
				mem.copy(u8, header_buffer[header_pos..], name);
				header_pos += name.len;
				header_buffer[header_pos] = ':';
				header_buffer[header_pos+1] = ' ';
				header_pos += 2;

				mem.copy(u8, header_buffer[header_pos..], value);
				header_pos += value.len;
				header_buffer[header_pos] = '\r';
				header_buffer[header_pos+1] = '\n';
				header_pos += 2;
			}
		}


		if (self.body) |body| {
			var b = body;
			if (self.pos > 0) {
				b = body[0..self.pos];
			}

			if (header_buffer.len < header_pos + 32) {
				try stream.writeAll(header_buffer[0..header_pos]);
				header_pos = 0;
			}
			mem.copy(u8, header_buffer[header_pos..], "Content-Length: ");
			header_pos += 16;
			header_pos += writeInt(header_buffer[header_pos..], @intCast(u32, b.len));
			header_buffer[header_pos] = '\r';
			header_buffer[header_pos+1] = '\n';
			header_buffer[header_pos+2] = '\r';
			header_buffer[header_pos+3] = '\n';
			try stream.writeAll(header_buffer[0..(header_pos+4)]);

			try stream.writeAll(b);
		} else {
			const fin = "Content-Length: 0\r\n\r\n";
			const final_pos = header_pos + fin.len;
			if (header_pos == 0) {
				try stream.writeAll(fin);
			} else if (header_buffer.len < final_pos) {
				try stream.writeAll(header_buffer[0..header_pos]);
				try stream.writeAll(fin);
			} else {
				mem.copy(u8, header_buffer[header_pos..], fin);
				try stream.writeAll(header_buffer[0..final_pos]);
			}
		}
	}

	pub fn writer(self: *Self) Writer.IOWriter {
		return .{.context = Writer.init(self)};
	}

	// writer optimized for std.json.stringify, but that can also be used as a
	// more generic writer.
	const Writer = struct {
		res: *Response,

		pub const Error = Allocator.Error;
		pub const IOWriter = std.io.Writer(Writer, error{OutOfMemory}, Writer.write);

		fn init(res: *Response) Writer {
			// We point our res.body to our body_buffer
			// When we write out the response, we'll check res.pos to see if this
			// needs to be sliced.
			// Also, if this writer needs to dynamically allocate a buffer,
			// it'll re-assign that to res.body.
			const buffer = res.body_buffer;
			res.body = buffer;
			res.writer_buffer = buffer;
			return Writer{.res = res};
		}

		pub fn writeByte(self: Writer, b: u8) !void {
			try self.ensureSpace(1);
			const pos = self.res.pos;
			self.res.writer_buffer[pos] = b;
			self.res.pos = pos + 1;
		}

		pub fn writeByteNTimes(self: Writer, b: u8, n: usize) !void {
			try self.ensureSpace(n);
			var pos = self.res.pos;
			const buffer = self.res.writer_buffer;
			for (0..n) |offset| {
				buffer[pos+offset] = b;
			}
			self.res.pos = pos + n;
		}

		pub fn writeAll(self: Writer, data: []const u8) !void {
			try self.ensureSpace(data.len);
			const pos = self.res.pos;
			std.mem.copy(u8, self.res.writer_buffer[pos..], data);
			self.res.pos = pos + data.len;
		}

		pub fn write(self: Writer, data: []const u8) Allocator.Error!usize {
			try self.writeAll(data);
			return data.len;
		}

		fn ensureSpace(self: Writer, n: usize) !void {
			const res = self.res;

			const pos = res.pos;
			const buffer = res.writer_buffer;
			const required_capacity = pos + n;

			if (buffer.len >= required_capacity) {
				// we have enough space in our body as-is
				return;
			}

			// taken from std.ArrayList
			var new_capacity = buffer.len;
			while (true) {
				new_capacity +|= new_capacity / 2 + 8;
				if (new_capacity >= required_capacity) break;
			}

			const arena = res.arena;

			// If this is our static body_buffer, we need to allocate a new dynamic space
			// If it's a dynamic buffer, we'll first try to resize it.
			// You might be thinking that in the 2nd case, we need to free the previous
			// body in the case that resize fails. We don't, because it'll be freed
			// when the arena is freed
			if (buffer.ptr == res.body_buffer.ptr or !arena.resize(buffer, new_capacity)) {
				const new_buffer = try arena.alloc(u8, new_capacity);
				mem.copy(u8, new_buffer, buffer);
				res.body = new_buffer;
				res.writer_buffer = new_buffer;
			} else {
				const new_buffer = buffer.ptr[0..new_capacity];
				res.body = new_buffer;
				res.writer_buffer = new_buffer;
			}
		}
	};
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
		res.body = "hello";
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

test "response: write header_buffer_size" {
	{
		// no header or bodys
		// 19 is the length of our longest header line
		for (19..40) |i| {
			var s = t.Stream.init();
			var res = testResponse(.{.header_buffer_size = i});
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
			var res = testResponse(.{.header_buffer_size = i});
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
			var res = testResponse(.{.header_buffer_size = i});
			defer testCleanup(res, s);

			res.status = 8;
			res.header("a-header", "a-value");
			res.header("b-hdr", "b-val");
			res.header("c-header11", "cv");
			res.body = "hello world!";
			try res.write(s);
			try t.expectString("HTTP/1.1 8\r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 12\r\n\r\nhello world!", s.received.items);
		}
	}
}

test "response: json fuzz" {
	var r = t.getRandom();
	const random = r.random();

	for (0..1) |_| {
		const body = t.randomString(random, t.allocator, 1000);
		defer t.allocator.free(body);
		const expected_encoded_length = body.len + 2; // wrapped in double quotes

		for (0..100) |i| {
			var s = t.Stream.init();
			var res = testResponse(.{.body_buffer_size = i});
			defer testCleanup(res, s);

			res.status = 200;
			try res.json(body);
			try res.write(s);

			const expected = try std.fmt.allocPrint(t.arena, "HTTP/1.1 200\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n\"{s}\"", .{expected_encoded_length, body});
			try t.expectString(expected, s.received.items);
		}
	}
}

test "response: writer fuzz" {
	var r = t.getRandom();
	const random = r.random();

	for (0..1) |_| {
		const body = t.randomString(random, t.allocator, 1000);
		defer t.allocator.free(body);
		const expected_encoded_length = body.len + 2; // wrapped in double quotes

		for (0..100) |i| {
			var s = t.Stream.init();
			var res = testResponse(.{.body_buffer_size = i});
			defer testCleanup(res, s);

			res.status = 204;
			try std.json.stringify(body, .{}, res.writer());
			try res.write(s);

			const expected = try std.fmt.allocPrint(t.arena, "HTTP/1.1 204\r\nContent-Length: {d}\r\n\r\n\"{s}\"", .{expected_encoded_length, body});
			try t.expectString(expected, s.received.items);
		}
	}
}

fn testResponse(config: Config) *Response {
	var res = t.allocator.create(Response) catch unreachable;
	res.init(t.allocator, t.arena, config) catch unreachable;
	return res;
}

fn testCleanup(r: *Response, s: *t.Stream) void {
	r.deinit(t.allocator);
	t.reset();
	t.allocator.destroy(r);
	defer s.deinit();
}
