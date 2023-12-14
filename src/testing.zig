// Helpers for application developers to be able to mock
// request and parse responses
const std = @import("std");
const t = @import("t.zig");
const httpz = @import("httpz.zig");

const Conn = @import("worker.zig").Conn;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub fn init(config: httpz.Config) Testing {
	const ctx = t.Context.init(config);
	var conn = ctx.conn;

	// Parse a basic request. This will put our conn.req_state into a valid state
	// for creating a request. Application code can modify the request directly
	// thereafter to change whatever properties they want.
	var base_request = std.io.fixedBufferStream("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
	while (true) {
		const done = conn.req_state.parse(&base_request) catch unreachable;
		if (done) {
			break;
		}
	}

	const aa = conn.arena.allocator();

	const req = aa.create(httpz.Request) catch unreachable;
	req.* = ctx.request();

	const res = aa.create(httpz.Response) catch unreachable;
	res.* = ctx.response();

	return Testing{
		._ctx = ctx,
		.req = req,
		.res = res,
		.arena = aa,
		.conn = ctx.conn,
	};
}

pub const Testing = struct {
	_ctx: t.Context,
	conn: *Conn,
	req: *httpz.Request,
	res: *httpz.Response,
	arena: std.mem.Allocator,
	parsed_response: ?Response = null,

	pub const Response = struct {
		status: u16,
		raw: []const u8,
		body: []const u8,
		allocator: std.mem.Allocator,
		headers: std.StringHashMap([]const u8),

		pub fn expectHeader(self: Response, name: []const u8, expected: ?[]const u8) !void {
			if (expected) |e| {
				try t.expectString(e, self.headers.get(name).?);
			} else {
				try t.expectEqual(null, self.headers.get(name));
			}
		}

		pub fn expectJson(self: Response, expected: anytype) !void {
			try t.expectString("application/json", self.headers.get("Content-Type").?);

			var jc = JsonComparer.init(t.allocator);
			defer jc.deinit();
			const diffs = try jc.compare(expected, self.body);
			if (diffs.items.len == 0) {
				return;
			}

			for (diffs.items, 0..) |diff, i| {
				std.debug.print("\n==Difference #{d}==\n", .{i+1});
				std.debug.print("  {s}: {s}\n  Left: {s}\n  Right: {s}\n", .{ diff.path, diff.err, diff.a, diff.b});
				std.debug.print("  Actual:\n    {s}\n", .{self.body});
			}
			return error.JsonNotEqual;
		}

		pub fn deinit(self: *Response) void {
			self.headers.deinit();
			self.allocator.free(self.raw);
		}
	};

	pub fn deinit(self: *Testing) void {
		self._ctx.deinit();
	}

	pub fn url(self: *Testing, u: []const u8) void {
		self.req.url = httpz.Url.parse(u);
	}

	pub fn param(self: *Testing, name: []const u8, value: []const u8) void {
		// This is ugly, but the Param structure is optimized for how the router
		// works, so we don't have a clean API for setting 1 key=value pair. We'll
		// just dig into the internals instead
		var p = &self.req.params;
		p.names[p.len] = name;
		p.values[p.len] = value;
		p.len += 1;
	}

	pub fn query(self: *Testing, name: []const u8, value: []const u8) void {
		const req = self.req;
		req.qs_read = true;
		req.qs.add(name, value);

		const encoded_name = std.Uri.escapeString(self.arena, name) catch unreachable;
		const encoded_value = std.Uri.escapeString(self.arena, value) catch unreachable;
		const kv = std.fmt.allocPrint(self.arena, "{s}={s}", .{encoded_name, encoded_value}) catch unreachable;

		const q = req.url.query;
		if (q.len == 0) {
			req.url.query = kv;
		} else {
			req.url.query = std.fmt.allocPrint(self.arena, "{s}&{s}", .{q, kv}) catch unreachable;
		}
	}

	pub fn header(self: *Testing, name: []const u8, value: []const u8) void {
		const lower = self.arena.alloc(u8, name.len) catch unreachable;
		_ = std.ascii.lowerString(lower, name);
		self.req.headers.add(lower, value);
	}

	pub fn body(self: *Testing, bd: []const u8) void {
		const mutable = self.arena.dupe(u8, bd) catch unreachable;
		self.req.body_buffer = .{.type = .static, .data = mutable};
		self.req.body_len = bd.len;
	}

	pub fn json(self: *Testing, value: anytype) void {
		var arr = ArrayList(u8).init(self.arena);
		defer arr.deinit();

		std.json.stringify(value, .{}, arr.writer()) catch unreachable;

		const bd = self.arena.alloc(u8, arr.items.len) catch unreachable;
		@memcpy(bd, arr.items);
		self.body(bd);
	}

	pub fn expectStatus(self: Testing, expected: u16) !void {
		try t.expectEqual(expected, self.res.status);
	}

	pub fn expectBody(self: *Testing, expected: []const u8) !void {
		const pr = try self.parseResponse();
		try t.expectString(expected, pr.body);
	}

	pub fn expectJson(self: *Testing, expected: anytype) !void {
		const pr = try self.parseResponse();
		try pr.expectJson(expected);
	}

	pub fn expectHeader(self: *Testing, name: []const u8, expected: ?[]const u8) !void {
		const pr = try self.parseResponse();
		return pr.expectHeader(name, expected);
	}

	pub fn expectHeaderCount(self: *Testing, expected: u32) !void {
		const pr = try self.parseResponse();
		try t.expectEqual(expected, pr.headers.count());
	}

	pub fn getJson(self: *Testing) !std.json.Value {
		const pr = try self.parseResponse();
		return try std.json.parseFromSliceLeaky(std.json.Value, self.arena, pr.body, .{});
	}

	pub fn parseResponse(self: *Testing) !Response {
		if (self.parsed_response) |r| return r;
		try self.res.write();
		self._ctx.close();

		const data = try self._ctx.read(self.arena);
		const pr = try parseWithAllocator(self.arena, data.items);
		self.parsed_response = pr;
		return pr;
	}
};

pub fn parse(data: []u8) !Testing.Response {
	return parseWithAllocator(t.allocator, data);
}

pub fn parseWithAllocator(allocator: Allocator, data: []u8) !Testing.Response {
	// data won't outlive this function, we want our Response to take ownership
	// of the full body, since it needs to reference parts of it.
	const raw = allocator.dupe(u8, data) catch unreachable;

	var status: u16 = 0;
	var header_length: usize = 0;
	var headers = std.StringHashMap([]const u8).init(allocator);

	var it = std.mem.splitSequence(u8, raw, "\r\n");
	if (it.next()) |line| {
		header_length = line.len + 2;
		status = try std.fmt.parseInt(u16, line[9..12], 10);
	} else {
		return error.InvalidResponseLine;
	}

	while (it.next()) |line| {
		header_length += line.len + 2;
		if (line.len == 0) break;
		if (std.mem.indexOfScalar(u8, line, ':')) |index| {
			// +2 to strip out the leading space
			headers.put(line[0..index], line[index+2..]) catch unreachable;
		} else {
			return error.InvalidHeader;
		}
	}

	var body_length = raw.len - header_length;
	if (headers.get("Transfer-Encoding")) |te| {
		if (std.mem.eql(u8, te, "chunked")) {
			body_length = decodeChunkedEncoding(raw[header_length..], data[header_length..]);
		}
	}

	return .{
		.raw = raw,
		.status = status,
		.headers = headers,
		.allocator = allocator,
		.body = raw[header_length..header_length + body_length],
	};
}

fn decodeChunkedEncoding(full_dest: []u8, full_src: []u8) usize {
	var src = full_src;
	var dest = full_dest;
	var length: usize = 0;

	while (true) {
		const nl = std.mem.indexOfScalar(u8, src, '\r') orelse unreachable;
		const chunk_length = std.fmt.parseInt(u32, src[0..nl], 16) catch unreachable;
		if (chunk_length == 0) {
			if (src[1] == '\r' and src[2] == '\n' and src[3] == '\r' and src[4] == '\n') {
				break;
			}
			continue;
		}

		@memcpy(dest[0..chunk_length], src[nl+2..nl+2+chunk_length]);
		length += chunk_length;

		dest = dest[chunk_length..];
		src = src[nl+4+chunk_length..];
	}
	return length;
}

const JsonComparer = struct {
	_arena: std.heap.ArenaAllocator,

	const Diff = struct {
		err: []const u8,
		path: []const u8,
		a: []const u8,
		b: []const u8,
	};

	fn init(allocator: Allocator) JsonComparer {
		return .{
			._arena = std.heap.ArenaAllocator.init(allocator),
		};
	}

	fn deinit(self: JsonComparer) void {
		self._arena.deinit();
	}

	// We compare by getting the string representation of a and b
	// and then parsing it into a std.json.ValueTree, which we can compare
	// Either a or b might already be serialized JSON string.
	fn compare(self: *JsonComparer, a: anytype, b: anytype) !ArrayList(Diff) {
		const allocator = self._arena.allocator();
		var a_bytes: []const u8 = undefined;
		if (@TypeOf(a) != []const u8) {
			// a isn't a string, let's serialize it
			a_bytes = try self.stringify(a);
		} else {
			a_bytes = a;
		}

		var b_bytes: []const u8 = undefined;
		if (@TypeOf(b) != []const u8) {
			// b isn't a string, let's serialize it
			b_bytes = try self.stringify(b);
		} else {
			b_bytes = b;
		}

		const a_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, a_bytes, .{});
		const b_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, b_bytes, .{});

		var diffs = ArrayList(Diff).init(allocator);
		var path = ArrayList([]const u8).init(allocator);
		try self.compareValue(a_value, b_value, &diffs, &path);
		return diffs;
	}

	fn compareValue(self: *JsonComparer, a: std.json.Value, b: std.json.Value, diffs: *ArrayList(Diff), path: *ArrayList([]const u8)) !void {
		const allocator = self._arena.allocator();

		if (!std.mem.eql(u8, @tagName(a), @tagName(b))) {
			diffs.append(self.diff("types don't match", path, @tagName(a), @tagName(b))) catch unreachable;
			return;
		}

		switch (a) {
			.null => {},
			.bool => {
				if (a.bool != b.bool) {
					diffs.append(self.diff("not equal", path, self.format(a.bool), self.format(b.bool))) catch unreachable;
				}
			},
			.integer => {
				if (a.integer != b.integer) {
					diffs.append(self.diff("not equal", path, self.format(a.integer), self.format(b.integer))) catch unreachable;
				}
			},
			.float => {
				if (a.float != b.float) {
					diffs.append(self.diff("not equal", path, self.format(a.float), self.format(b.float))) catch unreachable;
				}
			},
			.number_string => {
				if (!std.mem.eql(u8, a.number_string, b.number_string)) {
					diffs.append(self.diff("not equal", path, a.number_string, b.number_string)) catch unreachable;
				}
			},
			.string => {
				if (!std.mem.eql(u8, a.string, b.string)) {
					diffs.append(self.diff("not equal", path, a.string, b.string)) catch unreachable;
				}
			},
			.array => {
				const a_len = a.array.items.len;
				const b_len = b.array.items.len;
				if (a_len != b_len) {
					diffs.append(self.diff("array length", path, self.format(a_len), self.format(b_len))) catch unreachable;
					return;
				}
				for (a.array.items, b.array.items, 0..) |a_item, b_item, i| {
					try path.append(try std.fmt.allocPrint(allocator, "{d}", .{i}));
					try self.compareValue(a_item, b_item, diffs, path);
					_ = path.pop();
				}
			},
			.object => {
				var it = a.object.iterator();
				while (it.next()) |entry| {
					const key = entry.key_ptr.*;
					try path.append(key);
					if (b.object.get(key)) |b_item| {
						try self.compareValue(entry.value_ptr.*, b_item, diffs, path);
					} else {
						diffs.append(self.diff("field missing", path, key, "")) catch unreachable;
					}
					_ = path.pop();
				}
			},
		}
	}

	fn diff(self: *JsonComparer, err: []const u8, path: *ArrayList([]const u8), a_rep: []const u8, b_rep: []const u8) Diff {
		const full_path = std.mem.join(self._arena.allocator(), ".", path.items) catch unreachable;
		return .{
			.a = a_rep,
			.b = b_rep,
			.err = err,
			.path = full_path,
		};
	}

	fn stringify(self: *JsonComparer, value: anytype) ![]const u8 {
		var arr = ArrayList(u8).init(self._arena.allocator());
		try std.json.stringify(value, .{}, arr.writer());
		return arr.items;
	}

	fn format(self: *JsonComparer, value: anytype) []const u8 {
		return std.fmt.allocPrint(self._arena.allocator(), "{}", .{value}) catch unreachable;
	}
};

test "testing: params" {
	var ht = init(.{});
	defer ht.deinit();

	ht.param("id", "over9000");
	try t.expectString("over9000", ht.req.params.get("id").?);
	try t.expectEqual(null, ht.req.params.get("other"));
}

test "testing: query" {
	var ht = init(.{});
	defer ht.deinit();

	ht.query("search", "t:ea");
	ht.query("category", "447");

	const query = try ht.req.query();
	try t.expectString("t:ea", query.get("search").?);
	try t.expectString("447", query.get("category").?);
	try t.expectString("search=t%3Aea&category=447", ht.req.url.query);
	try t.expectEqual(null, query.get("other"));
}

test "testing: empty query" {
	var ht = init(.{});
	defer ht.deinit();

	const query = try ht.req.query();
	try t.expectEqual(0, query.len);
}

test "testing: query via url" {
	var ht = init(.{});
	defer ht.deinit();
	ht.url("/hello?duncan=idaho");

	const query = try ht.req.query();
	try t.expectString("idaho", query.get("duncan").?);
}

test "testing: header" {
	var ht = init(.{});
	defer ht.deinit();

	ht.header("Search", "tea");
	ht.header("Category", "447");

	try t.expectString("tea", ht.req.headers.get("search").?);
	try t.expectString("447", ht.req.headers.get("category").?);
	try t.expectEqual(null, ht.req.headers.get("other"));
}

test "testing: body" {
	var ht = init(.{});
	defer ht.deinit();

	ht.body("the body");
	try t.expectString("the body", ht.req.body().?);
}

test "testing: json" {
	var ht = init(.{});
	defer ht.deinit();

	ht.json(.{.over = 9000});
	try t.expectString("{\"over\":9000}", ht.req.body().?);
}

test "testing: expectBody empty" {
	var ht = init(.{});
	defer ht.deinit();
	try ht.expectStatus(200);
	try ht.expectBody("");
	try ht.expectHeaderCount(1);
	try ht.expectHeader("Content-Length", "0");
}

test "testing: expectBody" {
	var ht = init(.{});
	defer ht.deinit();
	ht.res.status = 404;
	ht.res.body = "nope";

	try ht.expectStatus(404);
	try ht.expectBody("nope");
}

test "testing: expectJson" {
	var ht = init(.{});
	defer ht.deinit();
	ht.res.status = 201;
	try ht.res.json(.{.tea = "keemun", .price = .{.amount = 4990, .discount = 0.1}}, .{});

	try ht.expectStatus(201);
	try ht.expectJson(.{ .price = .{.discount = 0.1, .amount = 4990}, .tea = "keemun"});
}

test "testing: getJson" {
	var ht = init(.{});
	defer ht.deinit();

	ht.res.status = 201;
	try ht.res.json(.{.tea = "silver needle"}, .{});

	try ht.expectStatus(201);
	const json = try ht.getJson();
	try t.expectString("silver needle", json.object.get("tea").?.string);
}

test "testing: parseResponse" {
	var ht = init(.{});
	defer ht.deinit();
	ht.res.status = 201;
	try ht.res.json(.{.tea = 33}, .{});

	try ht.expectStatus(201);
	const res = try ht.parseResponse();
	try t.expectEqual(201, res.status);
	try t.expectEqual(2, res.headers.count());
}
