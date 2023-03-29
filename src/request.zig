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
	max_body_size: usize = 1_048_576,
	buffer_size: usize = 65_8536,
	max_header_count: usize = 32,
	max_param_count: usize = 10,
	max_query_count: usize = 32,
};

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

	// The maximum body that we'll allow, take from the config object when the
	// request is first created.
	max_body_size: usize,

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
	// internally by this framework. The application is also free to make use of
	// this arena. This is the same arena as response.arena.
	arena: Allocator,

	const Self = @This();

	// Should not be called directly, but initialized through a pool, see server.zig reqResInit
	pub fn init(self: *Self, allocator: Allocator, arena: Allocator, config: Config) !void {
		self.arena = arena;
		self.stream = undefined;
		self.max_body_size = config.max_body_size;
		self.qs = try KeyValue.init(allocator, config.max_query_count);

		self.static = try allocator.alloc(u8, config.buffer_size);
		self.headers = try KeyValue.init(allocator, config.max_header_count);
		self.params = try Params.init(allocator, config.max_param_count);
		self.reset();
	}

	// Each parsing step (method, target, protocol, headers, body)
	// return (a) how much data they've read from the socket and
	// (b) how much data they've consumed. This informs the next step
	// about what's available and where to start.
	const ParseResult = struct {
		// how much the step used of the buffer
		used: usize,

		// total data read from the socket (by a particular step)
		read: usize,
	};

	pub fn deinit(self: *Self, allocator: Allocator) void {
		self.qs.deinit(allocator);
		self.params.deinit(allocator);
		self.headers.deinit(allocator);
		allocator.free(self.static);
	}

	pub fn reset(self: *Self) void {
		self.bd_read = false;
		self.bd = null;

		self.qs_read = false;
		self.qs.reset();

		self.params.reset();
		self.headers.reset();
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

	pub fn parse(self: *Self) !void {
		// Header must always fits inside our static buffer
		const buf = self.static;
		const stream = self.stream;

		var res = try self.parseMethod(stream, buf);
		var pos = res.used;
		var buf_len = res.read;

		res = try self.parseURL(stream, buf[pos..], buf_len - pos);
		pos += res.used;
		buf_len += res.read;

		res = try self.parseProtocol(stream, buf[pos..], buf_len - pos);
		pos += res.used;
		buf_len += res.read;

		while (true) {
			res = try self.parseOneHeader(stream, buf[pos..], buf_len - pos);
			const used = res.used;
			pos += used;
			buf_len += res.read;
			if (used == 2) { // it only consumed the trailing \r\n
				break;
			}
		}

		self.pos = pos;
		self.header_overread = buf_len - pos;
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

			if (length > self.max_body_size) {
				return error.BodyTooBig;
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
				buffer = try self.arena.alloc(u8, length);
				std.mem.copy(u8, buffer, self.static[pos..(pos+read)]);
			}

			while (read < length) {
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

	pub fn json(self: *Self, comptime T: type) !?T {
		const b = try self.body() orelse return null;
		var stream = std.json.TokenStream.init(b);
		return try std.json.parse(T, &stream, .{.allocator = self.arena});
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
					return .{.read = buf_len, .used = 4};
				},
				PUT_ => {
					self.method = .PUT;
					return .{.read = buf_len, .used = 4};
				},
				POST => {
					// only need 1 more byte, so at most, we need 1 more read
					if (buf_len < 5) buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != ' ') {
						return error.UnknownMethod;
					}
					self.method = .POST;
					return .{.read = buf_len, .used = 5};
				},
				HEAD => {
					// only need 1 more byte, so at most, we need 1 more read
					if (buf_len < 5) buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != ' ') {
						return error.UnknownMethod;
					}
					self.method = .HEAD;
					return .{.read = buf_len, .used = 5};
				},
				PATC => {
					while (buf_len < 6)  buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != 'H' or buf[5] != ' ') {
						return error.UnknownMethod;
					}
					self.method = .PATCH;
					return .{.read = buf_len, .used = 6};
				},
				DELE => {
					while (buf_len < 7) buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != 'T' or buf[5] != 'E' or buf[6] != ' ' ) {
						return error.UnknownMethod;
					}
					self.method = .DELETE;
					return .{.read = buf_len, .used = 7};
				},
				OPTI => {
					while (buf_len < 8) buf_len += try readForHeader(stream, buf[buf_len..]);
					if (buf[4] != 'O' or buf[5] != 'N' or buf[6] != 'S' or buf[7] != ' ' ) {
						return error.UnknownMethod;
					}
					self.method = .OPTIONS;
					return .{.read = buf_len, .used = 8};
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
			buf_len = try readForHeader(stream, buf);
		}

		switch (buf[0]) {
			'/' => {
				while (true) {
					if (std.mem.indexOfScalar(u8, buf[0..buf_len], ' ')) |end_index| {
						self.url = Url.parse(buf[0..end_index]);
						// +1 to consume the space
						return .{.used = end_index + 1, .read = buf_len - len};
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
				return .{.used = 2, .read = buf_len - len};
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

		return .{.read = buf_len - len, .used = 10};
	}

	fn parseOneHeader(self: *Self, stream: Stream, buf: []u8, len: usize) !ParseResult {
		var buf_len = len;

		while (true) {
			if (std.mem.indexOfScalar(u8, buf[0..buf_len], '\r')) |header_end| {

				const next = header_end + 1;
				if (next == buf_len) buf_len += try readForHeader(stream, buf[buf_len..]);

				if (buf[next] != '\n') {
					return error.InvalidHeaderLine;
				}

				if (header_end == 0) {
					return .{.read = buf_len - len, .used = 2};
				}

				if (std.mem.indexOfScalar(u8, buf[0..header_end], ':')) |name_end| {
					const name = buf[0..name_end];
					lowerCase(name);
					self.headers.add(name, trimLeadingSpace(buf[name_end+1..header_end]));
					return .{.read = buf_len - len, .used = next + 1};
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
		var allocator = self.arena;

		var it = std.mem.split(u8, raw, "&");
		while (it.next()) |pair| {
			if (std.mem.indexOfScalar(u8, pair, '=')) |sep| {
				const key = try Url.unescape(allocator, pair[0..sep]);
				const value = try Url.unescape(allocator, pair[sep+1..]);
				qs.add(key, value);
			} else {
				const key = try Url.unescape(allocator, pair);
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
	pub fn drain(self: *Self) !void {
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
				var n = if (buffer.len > length) buffer[0..length] else buffer;
				length -= try stream.read(n);
			}
		} else {
			// TODO: support chunked encoding
		}

		// This should not be necessary, since we expect the request to be reset
		// immediately after drain is called. However, it's a cheap thing
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
	BodyTooBig,
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
		defer testCleanup(r);
		try t.expectEqual(http.Method.GET, r.method);
	}

	{
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.PUT, r.method);
	}

	{
		const r = testParse("POST / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.POST, r.method);
	}

	{
		const r = testParse("HEAD / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.HEAD, r.method);
	}

	{
		const r = testParse("PATCH / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.PATCH, r.method);
	}

	{
		const r = testParse("DELETE / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.DELETE, r.method);
	}

	{
		const r = testParse("OPTIONS / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
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
		defer testCleanup(r);
		try t.expectString("/", r.url.raw);
	}

	{
		const r = testParse("PUT /api/v2 HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectString("/api/v2", r.url.raw);
	}

	{
		const r = testParse("DELETE /API/v2?hack=true&over=9000%20!! HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectString("/API/v2?hack=true&over=9000%20!!", r.url.raw);
	}

	{
		const r = testParse("PUT * HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
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
		defer testCleanup(r);
		try t.expectEqual(http.Protocol.HTTP10, r.protocol);
	}

	{
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
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
		defer testCleanup(r);
		try t.expectEqual(@as(usize, 0), r.headers.len);
	}

	{
		const r = testParse("PUT / HTTP/1.0\r\nHost: goblgobl.com\r\n\r\n", .{});
		defer testCleanup(r);

		try t.expectEqual(@as(usize, 1), r.headers.len);
		try t.expectString("goblgobl.com", r.headers.get("host").?);
	}

	{
		const r = testParse("PUT / HTTP/1.0\r\nHost: goblgobl.com\r\nMisc:  Some-Value\r\nAuthorization:none\r\n\r\n", .{});
		defer testCleanup(r);

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
		defer testCleanup(r);
		try t.expectEqual(true, r.canKeepAlive());
	}

	{
		// explicitly keepalive for 1.1
		const r = testParse("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(true, r.canKeepAlive());
	}

	{
		// explicitly not keepalive for 1.1
		const r = testParse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(false, r.canKeepAlive());
	}
}

test "request: query" {
	{
		// none
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(@as(usize, 0), (try r.query()).len);
	}

	{
		// none with path
		const r = testParse("PUT /why/would/this/matter HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(@as(usize, 0), (try r.query()).len);
	}

	{
		// value-less
		const r = testParse("PUT /?a HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		const query = try r.query();
		try t.expectEqual(@as(usize, 1), query.len);
		try t.expectString("", query.get("a").?);
		try t.expectEqual(@as(?[]const u8, null), query.get("b"));
	}

	{
		// single
		const r = testParse("PUT /?a=1 HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		const query = try r.query();
		try t.expectEqual(@as(usize, 1), query.len);
		try t.expectString("1", query.get("a").?);
		try t.expectEqual(@as(?[]const u8, null), query.get("b"));
	}

	{
		// multiple
		const r = testParse("PUT /path?Teg=Tea&it%20%20IS=over%209000%24&ha%09ck HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		const query = try r.query();
		try t.expectEqual(@as(usize, 3), query.len);
		try t.expectString("Tea", query.get("Teg").?);
		try t.expectString("over 9000$", query.get("it  IS").?);
		try t.expectString("", query.get("ha\tck").?);
	}
}

test "body: content-length" {
	{
		// too big
		const r = testParse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{.max_body_size = 9});
		defer testCleanup(r);
		try t.expectError(Error.BodyTooBig, r.body());
	}

	{
		// no body
		const r = testParse("PUT / HTTP/1.0\r\nHost: goblgobl.com\r\nContent-Length: 0\r\n\r\n", .{.max_body_size = 10});
		defer testCleanup(r);
		try t.expectEqual(@as(?[]const u8, null), try r.body());
		try t.expectEqual(@as(?[]const u8, null), try r.body());
	}

	{
		// fits into static buffer
		const r = testParse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
		defer testCleanup(r);
		try t.expectString("Over 9000!", (try r.body()).?);
		try t.expectString("Over 9000!", (try r.body()).?);
	}

	{
		// Requires dynamic buffer
		const r = testParse("POST / HTTP/1.0\r\nContent-Length: 11\r\n\r\nOver 9001!!", .{.buffer_size = 40 });
		defer testCleanup(r);
		try t.expectString("Over 9001!!", (try r.body()).?);
		try t.expectString("Over 9001!!", (try r.body()).?);
	}
}

test "body: json" {
	const Tea = struct {
		type: []const u8,
	};

	{
		// too big
		const r = testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{.max_body_size = 16});
		defer testCleanup(r);
		try t.expectError(Error.BodyTooBig, r.json(Tea));
	}

	{
		// no body
		const r = testParse("PUT / HTTP/1.0\r\nHost: goblgobl.com\r\nContent-Length: 0\r\n\r\n", .{.max_body_size = 10});
		defer testCleanup(r);
		try t.expectEqual(@as(?Tea, null), try r.json(Tea));
		try t.expectEqual(@as(?Tea, null), try r.json(Tea));
	}

	{
		// parses json
		const r = testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
		defer testCleanup(r);
		try t.expectString("keemun", (try r.json(Tea)).?.type);
		try t.expectString("keemun", (try r.json(Tea)).?.type);
	}
}

// our t.Stream already simulates random TCP fragmentation.
test "request: fuzz" {
	// We have a bunch of data to allocate for testing, like header names and
	// values. Easier to use this arena and reset it after each test run.
	var arena = std.heap.ArenaAllocator.init(t.allocator);
	const aa = arena.allocator();
	defer arena.deinit();

	var r = t.getRandom();
	const random = r.random();
	for (0..1) |_| {

		// important to test with different buffer sizes, since there's a lot of
		// special handling for different cases (e.g the buffer is full and has
		// some of the body in it, so we need to copy that to a dynamically allocated
		// buffer)

		// how many requests should we make on this 1 individual socket (simulating
		// keepalive AND the request pool)
		const buffer_size = random.uintAtMost(u16, 1024) + 1024;
		var request = testRequest(.{.buffer_size = buffer_size});
		defer {
			// normally the arena
			t.reset();
			request.deinit(t.allocator);
			t.allocator.destroy(request);
		}

		var s = t.Stream.init();
		defer s.deinit();

		request.stream = s;
		request.arena = t.arena;
		const number_of_requests = random.uintAtMost(u8, 10) + 1;
		for (0..number_of_requests) |_| {
			_ = arena.reset(.retain_capacity);
			const method = randomMethod(random);
			const url = t.randomString(random, aa, 20);

			_ = s.add(method);
			_ = s.add(" /");
			_ = s.add(url);

			const number_of_qs = random.uintAtMost(u8, 4);
			if (number_of_qs != 0) {
				_ = s.add("?");
			}
			var query = std.StringHashMap([]const u8).init(aa);
			for (0..number_of_qs) |_| {
				const key = t.randomString(random, aa, 20);
				const value = t.randomString(random, aa, 20);
				if (!query.contains(key)) {
					// TODO: figure out how we want to handle duplicate query values
					// (the spec doesn't specifiy what to do)
					query.put(key, value) catch unreachable;
					_ = s.add(key);
					_ = s.add("=");
					_ = s.add(value);
					_ = s.add("&");
				}
			}

			_ = s.add(" HTTP/1.1\r\n");

			var headers = std.StringHashMap([]const u8).init(aa);
			for (0..random.uintAtMost(u8, 4)) |_| {
				const name = t.randomString(random, aa, 20);
				const value = t.randomString(random, aa, 20);
				if (!headers.contains(name)) {
					// TODO: figure out how we want to handle duplicate query values
					// Note, the spec says we should merge these!
					headers.put(name, value) catch unreachable;
					_ = s.add(name);
					_ = s.add(": ");
					_ = s.add(value);
					_ = s.add("\r\n");
				}
			}

			var body: ?[]u8 = null;
			if (random.uintAtMost(u8, 4) == 0) {
				_ = s.add("\r\n"); // no body
			} else {
				body = t.randomString(random, aa, 8000);
				const cl = std.fmt.allocPrint(aa, "{d}", .{body.?.len}) catch unreachable;
				headers.put("content-length", cl) catch unreachable;
				_ = s.add("content-length: ");
				_ = s.add(cl);
				_ = s.add("\r\n\r\n");
				_ = s.add(body.?);
			}

			request.parse() catch |err| {
				std.debug.print("\nParse Error: {}\nInput: {s}", .{err, s.to_read.items[s.read_index..]});
				unreachable;
			};


			// assert the querystring
			var actualQuery = request.query() catch unreachable;
			var it = query.iterator();
			while (it.next()) |entry| {
				try t.expectString(entry.value_ptr.*, actualQuery.get(entry.key_ptr.*).?);
			}

			// assert the headers
			it = headers.iterator();
			while (it.next()) |entry| {
				try t.expectString(entry.value_ptr.*, request.header(entry.key_ptr.*).?);
			}

			// We dont' read the body by defalt. We donly read the body when the app
			// calls req.body(). It's important that we test both cases. When the body
			// isn't read, we still need to drain the bytes from the socket for when
			// the socket is reused.
			if (random.uintAtMost(u8, 4) != 0) {
				var actual = request.body() catch unreachable;
				if (body) |b| {
					try t.expectString(b, actual.?);
				} else {
					try t.expectEqual(@as(?[]const u8, null), actual);
				}
			}

			request.drain() catch unreachable;
			request.reset();
		}
	}
}

fn testParse(input: []const u8, config: Config) *Request {
	var s = t.Stream.init();
	_ = s.add(input);

	var request = testRequest(config);
	request.stream = s;
	request.arena = t.arena;
	request.parse() catch |err| {
		testCleanup(request);
		std.debug.print("\nParse Error: {}\nInput: {s}", .{err, input});
		unreachable;
	};
	return request;
}

fn expectParseError(expected: Error, input: []const u8, config: Config) !void {
	var s = t.Stream.init();
	_ = s.add(input);

	var request = testRequest(config);
	defer testCleanup(request);
	request.stream = s;
	try t.expectError(expected, request.parse());
}

fn testRequest(config: Config, ) *Request {
	var req = t.allocator.create(Request) catch unreachable;
	req.init(t.allocator, config) catch unreachable;
	return req;
}

fn testCleanup(r: *Request) void {
	r.stream.deinit();
	t.reset();
	r.deinit(t.allocator);
	t.allocator.destroy(r);
}

fn randomMethod(random: std.rand.Random) []const u8 {
	return switch (random.uintAtMost(usize, 6)) {
		0 => "GET",
		1 => "PUT",
		2 => "POST",
		3 => "PATCH",
		4 => "DELETE",
		5 => "OPTIONS",
		6 => "HEAD",
		else => unreachable,
	};
}
