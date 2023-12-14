const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz.zig");
const buffer = @import("buffer.zig");

const Conn = @import("worker.zig").Conn;
const KeyValue = @import("key_value.zig").KeyValue;
const Config = @import("config.zig").Config.Response;

const mem = std.mem;
const Stream = std.net.Stream;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Self = @This();

pub const Response = struct {
	// httpz's wrapper around a stream, the brave can access the underlying .stream
	conn: *Conn,

	// Where in body we're writing to. Used for dynamically writes to body, e.g.
	// via the json() or writer() functions
	pos: usize,

	// The status code to write.
	status: u16,

	// The response headers.
	// Using res.header(NAME, VALUE) is preferred.
	headers: KeyValue,

	// The content type. Use header("content-type", value) for a content type
	// which isn't available in the httpz.ContentType enum.
	content_type: ?httpz.ContentType,

	// An arena that will be reset at the end of each request. Can be used
	// internally by this framework. The application is also free to make use of
	// this arena. This is the same arena as request.arena.
	arena: Allocator,

	// whether or not we've already written the response
	written: bool,

	// Indicates that http.zig no longer owns this socket connection. App can
	// us this if it wants to take over ownership of the socket. We use it
	// when upgrading the connection to websocket.
	disowned: bool,

	// when false, the Connection: Close header is sent. This should not be set
	// directly, rather set req.keepalive = false.
	keepalive: bool,

	// The body to send. This value must remain valid until the response is sent
	// which happens outside of the application's control. It should be a constant
	// or created with res.arena. Use res.writer() for other cases.
	body: ?[]const u8,

	pub const State = Self.State;

	// Should not be called directly, but initialized through a pool
	pub fn init(arena: Allocator, conn: *Conn) Response {
		return .{
			.pos = 0,
			.body = null,
			.conn = conn,
			.status = 200,
			.arena = arena,
			.disowned = false,
			.written = false,
			.keepalive = true,
			.content_type = null,
			.headers = conn.res_state.headers,
		};
	}

	pub fn disown(self: *Response) void {
		self.written = true;
		self.disowned = true;
	}

	pub fn json(self: *Response, value: anytype, options: std.json.StringifyOptions) !void {
		try std.json.stringify(value, options, Writer.init(self));
		self.content_type = httpz.ContentType.JSON;
	}

	pub fn header(self: *Response, name: []const u8, value: []const u8) void {
		self.headers.add(name, value);
	}

	pub const HeaderOpts = struct {
		dupe_name: bool = false,
		dupe_value: bool = false,
	};

	pub fn headerOpts(self: *Response, name: []const u8, value: []const u8, opts: HeaderOpts) !void {
		const n = if (opts.dupe_name) try self.arena.dupe(u8, name) else name;
		const v = if (opts.dupe_name) try self.arena.dupe(u8, value) else name;
		self.headers.add(n, v);
	}

	pub fn startEventStream(self: *Response) !Stream {
		self.content_type = .EVENTS;
		self.headers.add("Cache-Control", "no-cache");
		self.headers.add("Connection", "keep-alive");

		const conn = self.conn;
		try conn.blocking();
		const stream = conn.stream;

		const state = &conn.res_state;
		try state.prepareForWrite(self);
		try stream.writeAll(state.header_buffer.data[0..state.header_len]);

		self.written = true;
		return stream;
	}

	// App wants to force the response to be written. Unfortunately, for the time
	// being, we achieve this by forcing the socket into blocking mode. This is
	// necessary since we don't have a mechanism for callbacks/async with the app.
	pub fn write(self: *Response) !void {
		if (self.written) return;
		self.written = true;

		const conn = self.conn;
		try conn.blocking();

		const state = &conn.res_state;
		try state.prepareForWrite(self);

		const stream = conn.stream;
		try stream.writeAll(state.header_buffer.data[0..state.header_len]);
		if (state.body) |b| {
			try stream.writeAll(b);
		}	else if (state.body_buffer) |b| {
			try stream.writeAll(b.data[0..state.body_len]);
		}
	}

	pub fn writer(self: *Response) Writer.IOWriter {
		return .{.context = Writer.init(self)};
	}

	pub fn directWriter(self: *Response) Writer {
		return Writer.init(self);
	}

	// writer optimized for std.json.stringify, but that can also be used as a
	// more generic std.io.Writer.
	pub const Writer = struct {
		state: *Self.State,

		pub const Error = Allocator.Error;
		pub const IOWriter = std.io.Writer(Writer, error{OutOfMemory}, Writer.write);

		fn init(res: *Response) Writer {
			const state = &res.conn.res_state;
			// safe to assume that we're going to have a body, we'll start by trying
			// to fit it in our static_body_buffer
			state.body_buffer = state.static_body_buffer;

			return .{
				.state = state,
			};
		}

		pub fn truncate(self: Writer, n: usize) void {
			const pos = self.state.body_len;
			const to_truncate = if (pos > n) n else pos;
			self.state.body_len = pos - to_truncate;
		}

		pub fn writeByte(self: Writer, b: u8) !void {
			try self.ensureSpace(1);
			const pos = self.state.body_len;
			self.state.body_buffer.?.data[pos] = b;
			self.state.body_len = pos + 1;
		}

		pub fn writeByteNTimes(self: Writer, b: u8, n: usize) !void {
			try self.ensureSpace(n);
			const pos = self.state.body_len;
			var buf = self.state.body_buffer.?.data;
			for (pos..pos+n) |i| {
				buf[i] = b;
			}
			self.state.body_len = pos + n;
		}

		pub fn writeAll(self: Writer, data: []const u8) !void {
			try self.ensureSpace(data.len);
			const pos = self.state.body_len;
			const end_pos = pos + data.len;
			@memcpy(self.state.body_buffer.?.data[pos..end_pos], data);
			self.state.body_len = end_pos;
		}

		pub fn write(self: Writer, data: []const u8) Allocator.Error!usize {
			try self.writeAll(data);
			return data.len;
		}

		pub fn print(self: Writer, comptime format: []const u8, args: anytype) Allocator.Error!void {
			return std.fmt.format(self, format, args);
		}

		fn ensureSpace(self: Writer, n: usize) !void {
			const state = self.state;
			const pos = state.body_len;
			const required_capacity = pos + n;
			const cap = self.state.body_buffer.?.data.len;

			if (cap > required_capacity) {
				return;
			}

			var new_capacity = cap;
			while (true) {
				new_capacity +|= new_capacity / 2 + 8;
				if (new_capacity >= required_capacity) break;
			}

			//  state.body_buffer _has_ to have been set (in the Writer.init call)
			state.body_buffer = try state.buffer_pool.grow(state.arena.allocator(), &state.body_buffer.?, pos, new_capacity);
		}
	};
};

// All the upfront memory allocation that we can do. Gets re-used from request
// to request.
pub const State = struct {
	// if our body is larger than our static buffer, it'll overflow here
	buffer_pool: *buffer.Pool,

	// re-used from request to request, exposed in via res.header(name, value
	headers: KeyValue,

	// position to start writing from. Depending on the stage, this could reference
	//a point in header_buffer.data or in body_buffer.data.
	pos: usize,

	// Static buffer for headers. Allocated upfront and used as long as the header
	// fits. Else, we'll grab something larger from the buffer_pool.
	static_header_buffer: buffer.Buffer,

	// Either points to static_header_buffer, or is something from the buffer pool
	// This is what we're writing.
	header_buffer: buffer.Buffer,

	// Length of header, when sending, we'll write: header_buffer.data[pos..header_len]
	header_len: usize,

	// The response body can either be given directly via res.body = "..." or written
	// through the res.writer() (which is what res.json() does). We could simplify
	// this code by taking anything assigned to res.body and writing it to our buffers,
	// but that would involve copying a potentially large string.
	body: ?[]const u8,

	// Static buffer for body. Allocated upfront and what we'll use if it fits. Else
	// we'll grab something larger from buffer_pool.
	static_body_buffer: buffer.Buffer,

	// Either points to static_body_buffer, or is something from the buffer pool
	// This is what we're writing. Null means no body
	body_buffer: ?buffer.Buffer,

	// Length of body, when sending, we'll write: body_buffer.data[pos..body_len];
	body_len: usize,

	// What we're currently writing, the header or the body. We need this so that
	// we know what to do when we've fully written buf. If we're in the "header"
	// stage, then we need to switch buf to our body and start writing the body (
	// thus entering the body stage). If we're in the body stage when we're done
	// writing buf, then we're done.
	stage: Stage,

	arena: *ArenaAllocator,

	const Stage = enum {
		header,
		body,
	};

	pub fn init(allocator: Allocator, arena: *ArenaAllocator, buffer_pool: *buffer.Pool, config: *const Config) !Response.State {
		var headers = try KeyValue.init(allocator, config.max_header_count orelse 16);
		errdefer headers.deinit(allocator);

		const header_buffer = try buffer_pool.static(config.header_buffer_size orelse 1024);
		errdefer buffer_pool.free(header_buffer);

		const body_buffer = try buffer_pool.static(config.body_buffer_size orelse 4096);
		errdefer buffer_pool.free(body_buffer);

		return .{
			.pos = 0,
			.body_len = 0,
			.header_len = 0,
			.stage = .header,
			.arena = arena,
			.buffer_pool = buffer_pool,
			.headers = headers,
			.body = null,
			.body_buffer = null,
			.header_buffer = header_buffer,
			.static_body_buffer = body_buffer,
			.static_header_buffer = header_buffer,
		};
	}

	pub fn deinit(self: *State, allocator: Allocator) void {
		// not our job to clear the arena!
		if (self.body_buffer) |buf| {
			self.buffer_pool.release(buf);
		}
		self.buffer_pool.free(self.static_body_buffer);

		self.buffer_pool.release(self.header_buffer);
		self.buffer_pool.free(self.static_header_buffer);

		self.headers.deinit(allocator);
	}

	pub fn reset(self: *State) void {
		// not our job to clear the arena!
		if (self.body_buffer) |buf| {
			self.buffer_pool.release(buf);
		}
		self.buffer_pool.release(self.header_buffer);
		self.header_buffer = self.static_header_buffer;

		self.pos = 0;
		self.body = null;
		self.body_len = 0;
		self.headers.reset();
	}

	pub fn prepareForWrite(self: *State, res: *Response) !void {
		self.stage = .header;
		self.body = res.body;

		var bp = self.buffer_pool;
		var buf = &self.static_header_buffer;
		var data = buf.data;

		var pos: usize = "HTTP/1.1 XXX\r\n".len;
		switch (res.status) {
			100 => @memcpy(data[0..14], "HTTP/1.1 100\r\n"),
			101 => @memcpy(data[0..14], "HTTP/1.1 101\r\n"),
			102 => @memcpy(data[0..14], "HTTP/1.1 102\r\n"),
			103 => @memcpy(data[0..14], "HTTP/1.1 103\r\n"),
			200 => @memcpy(data[0..14], "HTTP/1.1 200\r\n"),
			201 => @memcpy(data[0..14], "HTTP/1.1 201\r\n"),
			202 => @memcpy(data[0..14], "HTTP/1.1 202\r\n"),
			203 => @memcpy(data[0..14], "HTTP/1.1 203\r\n"),
			204 => @memcpy(data[0..14], "HTTP/1.1 204\r\n"),
			205 => @memcpy(data[0..14], "HTTP/1.1 205\r\n"),
			206 => @memcpy(data[0..14], "HTTP/1.1 206\r\n"),
			207 => @memcpy(data[0..14], "HTTP/1.1 207\r\n"),
			208 => @memcpy(data[0..14], "HTTP/1.1 208\r\n"),
			226 => @memcpy(data[0..14], "HTTP/1.1 226\r\n"),
			300 => @memcpy(data[0..14], "HTTP/1.1 300\r\n"),
			301 => @memcpy(data[0..14], "HTTP/1.1 301\r\n"),
			302 => @memcpy(data[0..14], "HTTP/1.1 302\r\n"),
			303 => @memcpy(data[0..14], "HTTP/1.1 303\r\n"),
			304 => @memcpy(data[0..14], "HTTP/1.1 304\r\n"),
			305 => @memcpy(data[0..14], "HTTP/1.1 305\r\n"),
			306 => @memcpy(data[0..14], "HTTP/1.1 306\r\n"),
			307 => @memcpy(data[0..14], "HTTP/1.1 307\r\n"),
			308 => @memcpy(data[0..14], "HTTP/1.1 308\r\n"),
			400 => @memcpy(data[0..14], "HTTP/1.1 400\r\n"),
			401 => @memcpy(data[0..14], "HTTP/1.1 401\r\n"),
			402 => @memcpy(data[0..14], "HTTP/1.1 402\r\n"),
			403 => @memcpy(data[0..14], "HTTP/1.1 403\r\n"),
			404 => @memcpy(data[0..14], "HTTP/1.1 404\r\n"),
			405 => @memcpy(data[0..14], "HTTP/1.1 405\r\n"),
			406 => @memcpy(data[0..14], "HTTP/1.1 406\r\n"),
			407 => @memcpy(data[0..14], "HTTP/1.1 407\r\n"),
			408 => @memcpy(data[0..14], "HTTP/1.1 408\r\n"),
			409 => @memcpy(data[0..14], "HTTP/1.1 409\r\n"),
			410 => @memcpy(data[0..14], "HTTP/1.1 410\r\n"),
			411 => @memcpy(data[0..14], "HTTP/1.1 411\r\n"),
			412 => @memcpy(data[0..14], "HTTP/1.1 412\r\n"),
			413 => @memcpy(data[0..14], "HTTP/1.1 413\r\n"),
			414 => @memcpy(data[0..14], "HTTP/1.1 414\r\n"),
			415 => @memcpy(data[0..14], "HTTP/1.1 415\r\n"),
			416 => @memcpy(data[0..14], "HTTP/1.1 416\r\n"),
			417 => @memcpy(data[0..14], "HTTP/1.1 417\r\n"),
			418 => @memcpy(data[0..14], "HTTP/1.1 418\r\n"),
			421 => @memcpy(data[0..14], "HTTP/1.1 421\r\n"),
			422 => @memcpy(data[0..14], "HTTP/1.1 422\r\n"),
			423 => @memcpy(data[0..14], "HTTP/1.1 423\r\n"),
			424 => @memcpy(data[0..14], "HTTP/1.1 424\r\n"),
			425 => @memcpy(data[0..14], "HTTP/1.1 425\r\n"),
			426 => @memcpy(data[0..14], "HTTP/1.1 426\r\n"),
			428 => @memcpy(data[0..14], "HTTP/1.1 428\r\n"),
			429 => @memcpy(data[0..14], "HTTP/1.1 429\r\n"),
			431 => @memcpy(data[0..14], "HTTP/1.1 431\r\n"),
			451 => @memcpy(data[0..14], "HTTP/1.1 451\r\n"),
			500 => @memcpy(data[0..14], "HTTP/1.1 500\r\n"),
			501 => @memcpy(data[0..14], "HTTP/1.1 501\r\n"),
			502 => @memcpy(data[0..14], "HTTP/1.1 502\r\n"),
			503 => @memcpy(data[0..14], "HTTP/1.1 503\r\n"),
			504 => @memcpy(data[0..14], "HTTP/1.1 504\r\n"),
			505 => @memcpy(data[0..14], "HTTP/1.1 505\r\n"),
			506 => @memcpy(data[0..14], "HTTP/1.1 506\r\n"),
			507 => @memcpy(data[0..14], "HTTP/1.1 507\r\n"),
			508 => @memcpy(data[0..14], "HTTP/1.1 508\r\n"),
			510 => @memcpy(data[0..14], "HTTP/1.1 510\r\n"),
			511 => @memcpy(data[0..14], "HTTP/1.1 511\r\n"),
			else => |s| {
				const HTTP1_1 = "HTTP/1.1 ";
				const l = HTTP1_1.len;
				@memcpy(data[0..l], HTTP1_1);
				pos = l + writeInt(data[l..], @as(u32, s));
				data[pos] = '\r';
				data[pos+1] = '\n';
				pos += 2;
			}
		}

		if (res.content_type) |ct| {
			const content_type: ?[]const u8 = switch (ct) {
				.BINARY => "Content-Type: application/octet-stream\r\n",
				.CSS => "Content-Type: text/css\r\n",
				.CSV => "Content-Type: text/csv\r\n",
				.EOT => "Content-Type: application/vnd.ms-fontobject\r\n",
				.EVENTS => "Content-Type: text/event-stream\r\n",
				.GIF => "Content-Type: image/gif\r\n",
				.GZ => "Content-Type: application/gzip\r\n",
				.HTML => "Content-Type: text/html\r\n",
				.ICO => "Content-Type: image/vnd.microsoft.icon\r\n",
				.JPG => "Content-Type: image/jpeg\r\n",
				.JS => "Content-Type: application/javascript\r\n",
				.JSON => "Content-Type: application/json\r\n",
				.OTF => "Content-Type: font/otf\r\n",
				.PDF => "Content-Type: application/pdf\r\n",
				.PNG => "Content-Type: image/png\r\n",
				.SVG => "Content-Type: image/svg+xml\r\n",
				.TAR => "Content-Type: application/x-tar\r\n",
				.TEXT => "Content-Type: text/plain\r\n",
				.TTF => "Content-Type: font/ttf\r\n",
				.WASM => "Content-Type: application/wasm\r\n",
				.WEBP => "Content-Type: image/webp\r\n",
				.WOFF => "Content-Type: font/woff\r\n",
				.WOFF2 => "Content-Type: font/woff2\r\n",
				.XML => "Content-Type: application/xml\r\n",
				.UNKNOWN => null,
			};
			if (content_type) |value| {
				const end = pos + value.len;
				@memcpy(data[pos..end], value);
				pos = end;
			}
		}

		if (res.keepalive == false) {
			const CLOSE_HEADER = "Connection: Close\r\n";
			const end = pos + CLOSE_HEADER.len;
			@memcpy(data[pos..end], CLOSE_HEADER);
			pos = end;
		}

		{
			const headers = &res.headers;
			const names = headers.keys[0..headers.len];
			const values = headers.values[0..headers.len];
			for (names, values) |name, value| {
				// +4 for the colon, space and trailer
				const header_line_length = name.len + value.len + 4;
				if (data.len < pos + header_line_length) {
					self.header_buffer = try bp.grow(self.arena.allocator(), buf, pos, data.len * 2);
					buf = &self.header_buffer;
					data = buf.data;
				}

				{
					// write the name
					const end = pos + name.len;
					@memcpy(data[pos..end], name);
					pos = end;
					data[pos] = ':';
					data[pos+1] = ' ';
					pos += 2;
				}

				{
					// write the value + trailer
					const end = pos + value.len;
					@memcpy(data[pos..end], value);
					pos = end;
					data[pos] = '\r';
					data[pos+1] = '\n';
					pos += 2;
				}
			}
		}

		// This is for our last header. 60 should be more than enough.
		if (data.len - pos < 60) {
			self.header_buffer = try bp.grow(self.arena.allocator(), buf, pos, data.len + 60);
			buf = &self.header_buffer;
			data = buf.data;
		}

		const body_len = if (self.body) |b| b.len else self.body_len;
		if (body_len > 0) {
			const CONTENT_LENGTH = "Content-Length: ";
			var end = pos + CONTENT_LENGTH.len;
			@memcpy(data[pos..end], CONTENT_LENGTH);
			pos = end;

			pos += writeInt(data[pos..], @intCast(body_len));
			end = pos + 4;
			@memcpy(data[pos..end], "\r\n\r\n");
			self.header_len = end;
		} else {
			const fin = blk: {
				if (res.content_type == .EVENTS) break :blk "\r\n";
				break :blk "Content-Length: 0\r\n\r\n";
			};
			const end = pos + fin.len;
			@memcpy(data[pos..end], fin);
			self.header_len = end;
		}
	}
};

fn writeInt(into: []u8, value: u32) usize {
	const small_strings = "00010203040506070809" ++
		"10111213141516171819" ++
		"20212223242526272829" ++
		"30313233343536373839" ++
		"40414243444546474849" ++
		"50515253545556575859" ++
		"60616263646566676869" ++
		"70717273747576777879" ++
		"80818283848586878889" ++
		"90919293949596979899";

	var v = value;
	var i: usize = 10;
	var buf: [10]u8 = undefined;
	while (v >= 100) {
		const digits = v % 100 * 2;
		v /= 100;
		i -= 2;
		buf[i+1] = small_strings[digits+1];
		buf[i] = small_strings[digits];
	}

	{
		const digits = v * 2;
		i -= 1;
		buf[i] = small_strings[digits+1];
		if (v >= 10) {
			i -= 1;
			buf[i] = small_strings[digits];
		}
	}

	const l = buf.len - i;
	@memcpy(into[0..l], buf[i..]);
	return l;
}

const t = @import("t.zig");
test "writeInt" {
	var buf: [10]u8 = undefined;
	var tst: [10]u8 = undefined;
	for (0..100_009) |i| {
		const expected_len = std.fmt.formatIntBuf(tst[0..], i, 10, .lower, .{});
		const l = writeInt(&buf, @intCast(i));
		try t.expectString(tst[0..expected_len], buf[0..l]);
	}
}

test "response: write" {
	var ctx = t.Context.init(.{});
	defer ctx.deinit();

	{
		// no body
		var res = ctx.response();
		res.status = 401;
		try res.write();
		try ctx.expect("HTTP/1.1 401\r\nContent-Length: 0\r\n\r\n");
	}

	{
		// body
		var res = ctx.response();
		res.status = 200;
		res.body = "hello";
		try res.write();
		try ctx.expect("HTTP/1.1 200\r\nContent-Length: 5\r\n\r\nhello");
	}
}

test "response: content_type" {
	var ctx = t.Context.init(.{});
	defer ctx.deinit();

	var res = ctx.response();
	res.content_type = httpz.ContentType.WEBP;
	try res.write();
	try ctx.expect("HTTP/1.1 200\r\nContent-Type: image/webp\r\nContent-Length: 0\r\n\r\n");
}

test "response: write header_buffer_size" {
	{
		// no header or bodys
		// 19 is the length of our longest header line
		for (19..40) |i| {
			var ctx = t.Context.init(.{.response = .{.header_buffer_size = i}});
			defer ctx.deinit();

			var res = ctx.response();
			res.status = 792;
			try res.write();
			try ctx.expect("HTTP/1.1 792\r\nContent-Length: 0\r\n\r\n");
		}
	}

	{
		// no body
		// 19 is the length of our longest header line
		for (19..110) |i| {
			var ctx = t.Context.init(.{.response = .{.header_buffer_size = i}});
			defer ctx.deinit();

			var res = ctx.response();
			res.status = 401;
			res.header("a-header", "a-value");
			res.header("b-hdr", "b-val");
			res.header("c-header11", "cv");
			try res.write();
			try ctx.expect("HTTP/1.1 401\r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 0\r\n\r\n");
		}
	}

	{
		// 22 is the length of our longest header line (the content-length)
		for (22..110) |i| {
			var ctx = t.Context.init(.{.response = .{.header_buffer_size = i}});
			defer ctx.deinit();

			var res = ctx.response();
			res.status = 8;
			res.header("a-header", "a-value");
			res.header("b-hdr", "b-val");
			res.header("c-header11", "cv");
			res.body = "hello world!";
			try res.write();
			try ctx.expect("HTTP/1.1 8\r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 12\r\n\r\nhello world!");
		}
	}
}

test "response: header" {
	{
		var ctx = t.Context.init(.{});
		defer ctx.deinit();

		var res = ctx.response();
		res.header("Key1", "Value1");
		try res.write();
		try ctx.expect("HTTP/1.1 200\r\nKey1: Value1\r\nContent-Length: 0\r\n\r\n");
	}

	{
		var ctx = t.Context.init(.{});
		defer ctx.deinit();

		var res = ctx.response();
		const k = try t.allocator.dupe(u8, "Key2");
		const v = try t.allocator.dupe(u8, "Value2");
		try res.headerOpts(k, v, .{.dupe_name = true, .dupe_value = true});
		t.allocator.free(k);
		t.allocator.free(v);
		try res.write();
		try ctx.expect("HTTP/1.1 200\r\nKey2: Value2\r\nContent-Length: 0\r\n\r\n");
	}
}

test "response: json fuzz" {
	var r = t.getRandom();
	const random = r.random();

	for (0..10) |_| {
		defer t.reset();
		const body = t.randomString(random, t.allocator, 1000);
		defer t.allocator.free(body);
		const expected_encoded_length = body.len + 2; // wrapped in double quotes

		for (0..100) |i| {
			var ctx = t.Context.init(.{.response = .{.body_buffer_size = i}});
			defer ctx.deinit();

			var res = ctx.response();
			res.status = 200;
			try res.json(body, .{});
			try res.write();

			const expected = try std.fmt.allocPrint(t.arena.allocator(), "HTTP/1.1 200\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n\"{s}\"", .{expected_encoded_length, body});
			try ctx.expect(expected);
		}
	}
}

test "response: writer fuzz" {
	var r = t.getRandom();
	const random = r.random();

	for (0..1) |_| {
		defer t.reset();
		const body = t.randomString(random, t.allocator, 1000);
		defer t.allocator.free(body);
		const expected_encoded_length = body.len + 2; // wrapped in double quotes

		for (0..100) |i| {
			var ctx = t.Context.init(.{.response = .{.body_buffer_size = i}});
			defer ctx.deinit();

			var res = ctx.response();
			res.status = 204;
			try std.json.stringify(body, .{}, res.writer());
			try res.write();

			const expected = try std.fmt.allocPrint(t.arena.allocator(), "HTTP/1.1 204\r\nContent-Length: {d}\r\n\r\n\"{s}\"", .{expected_encoded_length, body});
			try ctx.expect(expected);
		}
	}
}

test "response: direct writer" {
	defer t.reset();
	var ctx = t.Context.init(.{});
	defer ctx.deinit();

	var res = ctx.response();

	var writer = res.directWriter();
	writer.truncate(1);
	try writer.writeByte('[');
	writer.truncate(4);
	try writer.writeByte('[');
	try writer.writeAll("12345");
	writer.truncate(2);
	try writer.writeByte(',');
	try writer.writeAll("456");
	try writer.writeByte(',');
	writer.truncate(1);
	try writer.writeByte(']');

	try res.write();
	try ctx.expect("HTTP/1.1 200\r\nContent-Length: 9\r\n\r\n[123,456]");
}

test "response: written" {
	defer t.reset();
	var ctx = t.Context.init(.{});
	defer ctx.deinit();

	var res = ctx.response();

	res.body = "abc";
	try res.write();
	try ctx.expect("HTTP/1.1 200\r\nContent-Length: 3\r\n\r\nabc");

	// write again, without a res.reset, nothing gets written
	res.body = "yo!";
	try res.write();
	try ctx.expect("");
}
