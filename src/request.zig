const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
const http = @import("httpz.zig");

const Url = @import("url.zig").Url;
const Params = @import("params.zig").Params;
const KeyValue = @import("key_value.zig").KeyValue;

const Reader = std.io.Reader;
const Allocator = std.mem.Allocator;
const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;

// this approach to matching method name comes from zhp
const GET_ = @bitCast(u32, [4]u8{'G', 'E', 'T', ' '});
const PUT_ = @bitCast(u32, [4]u8{'P', 'U', 'T', ' '});
const POST = @bitCast(u32, [4]u8{'P', 'O', 'S', 'T'});
const HEAD = @bitCast(u32, [4]u8{'H', 'E', 'A', 'D'});
const PATC = @bitCast(u32, [4]u8{'P', 'A', 'T', 'C'});
const DELE = @bitCast(u32, [4]u8{'D', 'E', 'L', 'E'});
const OPTI = @bitCast(u32, [4]u8{'O', 'P', 'T', 'I'});
const HTTP = @bitCast(u32, [4]u8{'H', 'T', 'T', 'P'});
const V1P0 = @bitCast(u32, [4]u8{'/', '1', '.', '0'});
const V1P1 = @bitCast(u32, [4]u8{'/', '1', '.', '1'});

pub const Config = struct {
	pool_size: usize = 100,
	max_body_size: usize = 1_048_576,
	buffer_size: usize = 65_8536,
	max_header_count: usize = 32,
	max_param_count: usize = 10,
	max_query_count: usize = 32,
};

// Should not be called directly, but initialized through a pool
pub fn init(allocator: Allocator, config: Config) !*Request {
	var req = try allocator.create(Request);
	var arena = std.heap.ArenaAllocator.init(allocator);
	req.arena = arena;

	req.bd_read = false;
	req.bd = null;

	req.qs_read = false;
	req.qs = try KeyValue.init(allocator, config.max_query_count);

	req.stream = undefined;
	req.static = try allocator.alloc(u8, config.buffer_size);
	req.headers = try KeyValue.init(allocator, config.max_header_count);
	req.params = try Params.init(allocator, config.max_param_count);
	return req;
}

pub const Request = struct {
	// The URL of the request
	url: Url,

	// the underlying socket to read from
	stream: Stream,

	// Path params (extracted from the URL based on the route).
	// Using req.param(NAME) is preferred.
	params: Params,

	// The headers of the request. Using req.header(NAME) is preferred.
	headers: KeyValue,

	// The request method.
	method: http.Method,

	// The request protocol.
	protocol: http.Protocol,

	// Whether or not the body has been read.
	// Used for two reasons. First, we only lazily read the body.
	// Second, for keepalive, if the body wasn't read as part of the normal
	// request handling, we need to discard it from the stream.
	bd_read: bool,
	// The body of the request, if any.
	bd: ?[]const u8,

	// cannot use an optional on qs, because it's pre-allocated so always exists
	qs_read: bool,
	// The query string lookup.
	qs: KeyValue,

	// Where in static we currently are. This is needed so that we can tell if
	// the body can be read directly in static or not (if there's enough space).
	pos: usize,

	// When parsing our header, we're reading as much data as possible from the
	// the socket. This means we might read some of the body into our static buffer
	// as part of the "header" parsing. We need to know how much of static is the
	// already-read body so that when it comes time to actually read the body, we
	// know how much we've already done.
	header_overread: usize,


	// A buffer that exists for the entire lifetime of the request. The sized
	// is defined by the request.buffer_size configuration. The request header MUST
	// fit in this size (requests with headers larger than this will be rejected).
	// If possible, this space will also be used for the body.
	static: []u8,

	// An arena that will be reset at the end of each request. Can be used
	// internally by this framework, or externally by the application.
	arena: std.heap.ArenaAllocator,

	const Self = @This();

	// Each parsing step (method, target, protocol, headers, body)
	// return (a) how much data they've read from the socket and
	// (b) how much data they've consumed. This informs the next step
	// about what's available and where to start.
	const ParseResult = struct {
		// how much the step used of the buffer
		used: usize,

		// total data read from the socket (by a particular step)
		buf_len: usize,
	};

	pub fn deinit(self: *Self, allocator: Allocator) void {
		self.qs.deinit();
		self.params.deinit();
		self.headers.deinit();
		allocator.free(self.static);
		self.arena.deinit();
	}

	pub fn reset(self: *Self) void {
		self.bd_read = false;
		self.bd = null;

		self.qs_read = false;
		self.qs.reset();

		self.params.reset();
		self.headers.reset();
		_ = self.arena.reset(std.heap.ArenaAllocator.ResetMode.free_all);
	}

	pub fn header(self: *Self, name: []const u8) ?[]const u8 {
		return self.headers.get(name);
	}

	pub fn param(self: *Self, name: []const u8) ?[]const u8 {
		return self.params.get(name);
	}

	pub fn query(self: *Self) !KeyValue {
		if (self.qs_read) {
			return self.qs;
		}
		return self.parseQuery();
	}

	pub fn parse(self: *Self, stream: Stream) !void {
		self.stream = stream;
		try self.parseHeader();
	}

	pub fn body(self: *Self) !?[]const u8 {
		if (self.bd_read) {
			return self.bd;
		}

		self.bd_read = true;
		const stream = self.stream;

		if (self.header("content-length")) |cl| {
			var length = atoi(cl) orelse return error.InvalidContentLength;
			if (length == 0) {
				self.bd = null;
				return null;
			}

			const pos = self.pos;

			// some (or all) of the body might have already been read into static
			// when we were loading data as part of reading the header.
			var read = self.header_overread;

			if (read == length) {
				// we're already read the entire body into static
				self.bd = self.static[pos..(pos+read)];
				return self.bd;
			}

			var buffer = self.static[pos..];
			if (length > buffer.len) {
				buffer = try self.arena.allocator().alloc(u8, length);
				std.mem.copy(u8, buffer, self.static[pos..(pos+read)]);
			}

			while (read < length) {
				// std.debug.print("READ {d} {d} {d} {s} {s}\n", .{read, length, buffer.len, buffer[0..read], buffer[0..length]});
				const n = try stream.read(buffer[read..]);
				if (n == 0) {
					return Error.ConnectionClosed;
				}
				read += n;
			}
			buffer = buffer[0..length];
			self.bd = buffer;
			return buffer;
		}
		// TODO: support chunked encoding
		return self.bd;
	}

	fn parseHeader(self: *Self) !void {
		// Header must always fits inside our static buffer
		const buf = self.static;
		const stream = self.stream;

		var res = try self.parseMethod(stream, buf);
		var pos = res.used;
		var buf_len = res.buf_len;

		res = try self.parseURL(stream, buf[pos..], buf_len - pos);
		pos += res.used;
		buf_len += res.buf_len;

		res = try self.parseProtocol(stream, buf[pos..], buf_len - pos);
		pos += res.used;
		buf_len += res.buf_len;


		while (true) {
			res = try self.parseOneHeader(stream, buf[pos..], buf_len - pos);
			buf_len += res.buf_len;
			pos += res.used;
			if (res.used == 2) { // it only consumed the trailing \r\n
				break;
			}
		}

		self.pos = pos;
		self.header_overread = buf_len - pos;
	}

	fn parseMethod(self: *Self, stream: Stream, buf: []u8) !ParseResult {
		var buf_len: usize = 0;
		while (buf_len < 4) {
			buf_len += try readForHeader(stream, buf[buf_len..]);
		}

		while (true) {
			const used = switch (@bitCast(u32, buf[0..4].*)) {
				GET_ => {
					self.method = .GET;
					return .{.buf_len = buf_len, .used = 4};
				},
				PUT_ => {
					self.method = .PUT;
					return .{.buf_len = buf_len, .used = 4};
				},
				POST => {
					// only need 1 more byte, so at most, we need 1 more read
					if (buf_len < 5) buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != ' ') {
						return error.UnknownMethod;
					}
					self.method = .POST;
					return .{.buf_len = buf_len, .used = 5};
				},
				HEAD => {
					// only need 1 more byte, so at most, we need 1 more read
					if (buf_len < 5) buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != ' ') {
						return error.UnknownMethod;
					}
					self.method = .HEAD;
					return .{.buf_len = buf_len, .used = 5};
				},
				PATC => {
					while (buf_len < 6)  buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != 'H' or buf[5] != ' ') {
						return error.UnknownMethod;
					}
					self.method = .PATCH;
					return .{.buf_len = buf_len, .used = 6};
				},
				DELE => {
					while (buf_len < 7) buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != 'T' or buf[5] != 'E' or buf[6] != ' ' ) {
						return error.UnknownMethod;
					}
					self.method = .DELETE;
					return .{.buf_len = buf_len, .used = 7};
				},
				OPTI => {
					while (buf_len < 8) buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != 'O' or buf[5] != 'N' or buf[6] != 'S' or buf[7] != ' ' ) {
						return error.UnknownMethod;
					}
					self.method = .OPTIONS;
					return .{.buf_len = buf_len, .used = 8};
				},
				else => return error.UnknownMethod,
			};

			return ParseResult{
				.used = used,
				.read = buf_len,
			};
		}
	}

	fn parseURL(self: *Self, stream: Stream, buf: []u8, len: usize) !ParseResult {
		var buf_len = len;
		if (buf_len == 0) {
			buf_len += try readForHeader(stream, buf);
		}

		switch (buf[0]) {
			'/' => {
				while (true) {
					if (std.mem.indexOfScalar(u8, buf, ' ')) |end_index| {
						var target = buf[0..end_index];
						_ = std.ascii.lowerString(target, target);
						self.url = Url.parse(target);
						// +1 to consume the space
						return .{.used = end_index + 1, .buf_len = buf_len - len};
					}
					buf_len += try readForHeader(stream, buf[buf_len..]);
				}
			},
			'*' => {
				// must be a "* ", so we need at least 1 more byte
				if (buf_len == 1) {
					buf_len += try readForHeader(stream, buf[buf_len..]);
				}
				// Read never returns 0, so if we're here, buf.len >= 1
				if (buf[1] != ' ') {
					return error.InvalidRequestTarget;
				}
				self.url = Url.star();
				return .{.used = 2, .buf_len = buf_len - len};
			},
			// TODO: Support absolute-form target (e.g. http://....)
			else => return error.InvalidRequestTarget,
		}
	}

	fn parseProtocol(self: *Self, stream: Stream, buf: []u8, len: usize) !ParseResult {
		var buf_len = len;
		while (buf_len < 10) {
			buf_len += try readForHeader(stream, buf[buf_len..]);
		}
		if (@bitCast(u32, buf[0..4].*) != HTTP) {
			return error.UnknownProtocol;
		}
		switch (@bitCast(u32, buf[4..8].*)) {
			V1P1 => self.protocol = http.Protocol.HTTP11,
			V1P0 => self.protocol = http.Protocol.HTTP10,
			else => return error.UnsupportedProtocol,
		}

		if (buf[8] != '\r' or buf [9] != '\n') {
			return error.UnknownProtocol;
		}

		return .{.buf_len = buf_len - len, .used = 10};
	}

	fn parseOneHeader(self: *Self, stream: Stream, buf: []u8, len: usize) !ParseResult {
		var buf_len = len;

		while (true) {
			if (std.mem.indexOfScalar(u8, buf, '\r')) |header_end| {

				const next = header_end + 1;
				if (next == buf_len) buf_len += try readForHeader(stream, buf[buf_len..]);

				if (buf[next] != '\n') {
					return error.InvalidHeaderLine;
				}

				if (header_end == 0) {
					return .{.buf_len = buf_len - len, .used = 2};
				}

				if (std.mem.indexOfScalar(u8, buf[0..header_end], ':')) |name_end| {
					const name = buf[0..name_end];
					lowerCase(name);
					self.headers.add(name, trimLeadingSpace(buf[name_end+1..header_end]));
					return .{.buf_len = buf_len - len, .used = next + 1};
				} else {
					return error.InvalidHeaderLine;
				}
			}
			buf_len += try readForHeader(stream, buf[buf_len..]);
		}
	}

	fn parseQuery(self: *Self) !KeyValue {
		const raw = self.url.query;
		if (raw.len == 0) {
			self.qs_read = true;
			return self.qs;
		}

		var qs = &self.qs;
		var allocator = self.arena.allocator();

		var it = std.mem.split(u8, raw, "&");
		while (it.next()) |pair| {
			if (std.mem.indexOfScalar(u8, pair, '=')) |sep| {
				const key = try std.Uri.unescapeString(allocator, pair[0..sep]);
				const value = try std.Uri.unescapeString(allocator, pair[sep+1..]);
				qs.add(key, value);
			} else {
				const key = try std.Uri.unescapeString(allocator, pair);
				qs.add(key, "");
			}
		}

		self.qs_read = true;
		return self.qs;
	}

	// Drains the body from the socket (if it hasn't already been read). This is
	// only necessary during keepalive requests. We don't care about the contents
	// of the body, we just want to move the socket to end of this request (which
	// would be the start of the next one).
	// We assume the request will be reset after this is called, so its ok for us
	// to c the static buffer (which various header elements point to)
	pub fn drainRequest(self: *Self) !void {
		if (self.bd_read == true) {
			// body has already been read
			return;
		}

		const stream = self.stream;
		if (self.header("content-length")) |value| {
			var buffer = self.static;
			var length = atoi(value) orelse return error.InvalidContentLength;

			// some (or all) of the body might have already been read into static
			// when we were loading data as part of reading the header.
			length -= self.header_overread;

			while (length > 0) {
				var drain = if (buffer.len > length) buffer[0..length] else buffer;
				length -= try stream.read(drain);
			}
		} else {
			// TODO: support chunked encoding
		}

		// This should not be necessary, since we expect the request to be reset
		// immediately after drainRequest is called. However, it's a cheap thing
		// to add which might prevent weird accidental interactions.
		self.bd_read = true;
	}

	pub fn canKeepAlive(self: *Self) bool {
		return switch (self.protocol) {
			http.Protocol.HTTP11 => {
				if (self.headers.get("connection")) |conn| {
					return !std.mem.eql(u8, conn, "close");
				}
				return true;
			},
			http.Protocol.HTTP10 => return false, // TODO: support this in the cases where it can be
		};
	}
};

fn trimLeadingSpace(in: []const u8) []const u8 {
	for (in, 0..) |b, i| {
		if (b != ' ') return in[i..];
	}
	return "";
}

fn lowerCase(value: []u8) void {
	for (value, 0..) |c, i| {
		value[i] = std.ascii.toLower(c);
	}
}

fn readForHeader(stream: Stream, buffer: []u8) !usize {
	const n = try stream.read(buffer);
	if (n == 0) {
		if (buffer.len == 0) {
			return error.HeaderTooBig;
		}
		return error.ConnectionClosed;
	}
	return n;
}

fn atoi(str: []const u8) ?usize {
	if (str.len == 0) {
		return null;
	}

	var n: usize = 0;
	for (str) |b| {
		var d = b - '0';
		if (d > 9) {
			return null;
		}
		n = n * 10 + @intCast(usize, d);
	}
	return n;
}

test "atoi" {
	var buf: [5]u8 = undefined;
	for (0..99999) |i| {
		const n = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
		try t.expectEqual(@intCast(usize, i), atoi(buf[0..n]).?);
	}

	try t.expectEqual(@as(?usize, null), atoi(""));
	try t.expectEqual(@as(?usize, null), atoi("392a"));
	try t.expectEqual(@as(?usize, null), atoi("b392"));
	try t.expectEqual(@as(?usize, null), atoi("3c92"));
}

const Error = error {
	HeaderTooBig,
	ConnectionClosed,
	UnknownMethod,
	InvalidRequestTarget,
	UnknownProtocol,
	UnsupportedProtocol,
	InvalidHeaderLine,
	InvalidContentLength,
};

test "request: header too big" {
	try expectParseError(Error.HeaderTooBig, "GET / HTTP/1.1\r\n\r\n", .{.buffer_size = 17});
	try expectParseError(Error.HeaderTooBig, "GET / HTTP/1.1\r\nH: v\r\n\r\n", .{.buffer_size = 23});
}

test "request: parse method" {
	{
		try expectParseError(Error.ConnectionClosed, "GET", .{});
		try expectParseError(Error.UnknownMethod, "GETT ", .{});
		try expectParseError(Error.UnknownMethod, " PUT ", .{});
	}

	{
		const r = testParse("GET / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Method.GET, r.method);
	}

	{
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Method.PUT, r.method);
	}

	{
		const r = testParse("POST / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Method.POST, r.method);
	}

	{
		const r = testParse("HEAD / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Method.HEAD, r.method);
	}

	{
		const r = testParse("PATCH / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Method.PATCH, r.method);
	}

	{
		const r = testParse("DELETE / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Method.DELETE, r.method);
	}

	{
		const r = testParse("OPTIONS / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Method.OPTIONS, r.method);
	}
}

test "request: parse request target" {
	{
		try expectParseError(Error.InvalidRequestTarget, "GET NOPE", .{});
		try expectParseError(Error.InvalidRequestTarget, "GET nope ", .{});
		try expectParseError(Error.InvalidRequestTarget, "GET http://www.goblgobl.com/test ", .{}); // this should be valid
		try expectParseError(Error.InvalidRequestTarget, "PUT hello ", .{});
		try expectParseError(Error.InvalidRequestTarget, "POST  /hello ", .{});
		try expectParseError(Error.InvalidRequestTarget, "POST *hello ", .{});
	}

	{
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectString("/", r.url.raw);
	}

	{
		const r = testParse("PUT /api/v2 HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectString("/api/v2", r.url.raw);
	}

	{
		const r = testParse("DELETE /API/v2?hack=true&over=9000%20!! HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectString("/api/v2?hack=true&over=9000%20!!", r.url.raw);
	}

	{
		const r = testParse("PUT * HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectString("*", r.url.raw);
	}
}

test "request: parse protocol" {
	{
		try expectParseError(Error.ConnectionClosed, "GET / ", .{});
		try expectParseError(Error.ConnectionClosed, "GET /  ", .{});
		try expectParseError(Error.ConnectionClosed, "GET / H\r\n", .{});
		try expectParseError(Error.UnknownProtocol, "GET / http/1.1\r\n", .{});
		try expectParseError(Error.UnsupportedProtocol, "GET / HTTP/2.0\r\n", .{});
	}

	{
		const r = testParse("PUT / HTTP/1.0\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Protocol.HTTP10, r.protocol);
	}

	{
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(http.Protocol.HTTP11, r.protocol);
	}
}

test "request: parse headers" {
	{
		try expectParseError(Error.ConnectionClosed, "GET / HTTP/1.1\r\nH", .{});
		try expectParseError(Error.InvalidHeaderLine, "GET / HTTP/1.1\r\nHost\r\n", .{});
		try expectParseError(Error.ConnectionClosed, "GET / HTTP/1.1\r\nHost:another\r\n\r", .{});
		try expectParseError(Error.ConnectionClosed, "GET / HTTP/1.1\r\nHost: goblgobl.com\r\n", .{});
	}

	{
		const r = testParse("PUT / HTTP/1.0\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(@as(usize, 0), r.headers.len);
	}

	{
		const r = testParse("PUT / HTTP/1.0\r\nHost: goblgobl.com\r\n\r\n", .{});
		defer cleanupRequest(r);

		try t.expectEqual(@as(usize, 1), r.headers.len);
		try t.expectString("goblgobl.com", r.headers.get("host").?);
	}

	{
		const r = testParse("PUT / HTTP/1.0\r\nHost: goblgobl.com\r\nMisc:  Some-Value\r\nAuthorization:none\r\n\r\n", .{});
		defer cleanupRequest(r);

		try t.expectEqual(@as(usize, 3), r.headers.len);
		try t.expectString("goblgobl.com", r.header("host").?);
		try t.expectString("Some-Value", r.header("misc").?);
		try t.expectString("none", r.header("authorization").?);
	}
}

test "request: canKeepAlive" {
	{
		// implicitly keepalive for 1.1
		const r = testParse("GET / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(true, r.canKeepAlive());
	}

	{
		// explicitly keepalive for 1.1
		const r = testParse("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(true, r.canKeepAlive());
	}

	{
		// explicitly not keepalive for 1.1
		const r = testParse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(false, r.canKeepAlive());
	}
}

test "request: query" {
	{
		// none
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(@as(usize, 0), (try r.query()).len);
	}

	{
		// none with path
		const r = testParse("PUT /why/would/this/matter HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(@as(usize, 0), (try r.query()).len);
	}

	{
		// value-less
		const r = testParse("PUT /?a HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		const query = try r.query();
		try t.expectEqual(@as(usize, 1), query.len);
		try t.expectString("", query.get("a").?);
		try t.expectEqual(@as(?[]const u8, null), query.get("b"));
	}

	{
		// single
		const r = testParse("PUT /?a=1 HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		const query = try r.query();
		try t.expectEqual(@as(usize, 1), query.len);
		try t.expectString("1", query.get("a").?);
		try t.expectEqual(@as(?[]const u8, null), query.get("b"));
	}

	{
		// multiple
		const r = testParse("PUT /path?Teg=Tea&it%20%20IS=over%209000%24&ha%09ck HTTP/1.1\r\n\r\n", .{});
		defer cleanupRequest(r);
		const query = try r.query();
		try t.expectEqual(@as(usize, 3), query.len);
		try t.expectString("tea", query.get("teg").?);
		try t.expectString("over 9000$", query.get("it  is").?);
		try t.expectString("", query.get("ha\tck").?);
	}
}

test "body: content-length" {
	{
		// no body
		const r = testParse("PUT / HTTP/1.0\r\nHost: goblgobl.com\r\nContent-Length: 0\r\n\r\n", .{});
		defer cleanupRequest(r);
		try t.expectEqual(@as(?[]const u8, null), try r.body());
		try t.expectEqual(@as(?[]const u8, null), try r.body());
	}

	{
		// fits into static buffer
		const r = testParse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
		defer cleanupRequest(r);
		try t.expectString("Over 9000!", (try r.body()).?);
		try t.expectString("Over 9000!", (try r.body()).?);
	}

	{
		// Requires dynamic buffer
		const r = testParse("POST / HTTP/1.0\r\nContent-Length: 11\r\n\r\nOver 9001!!", .{.buffer_size = 40 });
		defer cleanupRequest(r);
		try t.expectString("Over 9001!!", (try r.body()).?);
		try t.expectString("Over 9001!!", (try r.body()).?);
	}
}

fn testParse(input: []const u8, config: Config) *Request {
	var s = t.Stream.init();
	_ = s.add(input);

	var request = init(t.allocator, config) catch unreachable;
	request.parse(s) catch |err| {
		cleanupRequest(request);
		std.debug.print("\nparse err: {}\n", .{err});
		unreachable;
	};
	return request;
}

fn expectParseError(expected: Error, input: []const u8, config: Config) !void {
	var s = t.Stream.init();
	_ = s.add(input);

	var request = try init(t.allocator, config);
	defer cleanupRequest(request);
	try t.expectError(expected, request.parse(s));
}

// We need this because we use init to create the request (the way the real
// code does, for pooling), so we need to free(r) not just deinit it.
fn cleanupRequest(r: *Request) void {
	r.stream.deinit();
	r.deinit(t.allocator);
	t.allocator.destroy(r);
}
