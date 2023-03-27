// Helpers for application developers to be able to mock
// request and parse responses
const std = @import("std");
const t = @import("t.zig");
const httpz = @import("httpz.zig");

pub fn init(config: httpz.Config) Testing {
	var req = t.allocator.create(httpz.Request) catch unreachable;
	req.init(t.allocator, config.request) catch unreachable;
	req.url = httpz.Url.parse("/");

	var res = t.allocator.create(httpz.Response) catch unreachable;
	res.init(t.allocator, config.response) catch unreachable;


	return Testing{
		.req = req,
		.res = res,
		.arena = std.heap.ArenaAllocator.init(t.allocator),
	};
}

pub const Testing = struct {
	req: *httpz.Request,
	res: *httpz.Response,
	arena: std.heap.ArenaAllocator,
	free_body: bool = false,
	parsed_response: ?Response = null,

	const Self = @This();

	const Response = struct {
		status: u16,
		raw: []const u8,
		body: []const u8,
		// Only populated if getJson() is called. Need to keep it around as we
		// need to free the memory it allocated
		json_value: ?std.json.ValueTree,
		headers: std.StringHashMap([]const u8),
	};

	pub fn deinit(self: *Self) void {
		// the header function lowercased the provided header name (to be
		// consistent with the real request parsing, so we need to free that memory)
		const headers = self.req.headers;
		for (0..headers.len) |i| {
			t.allocator.free(headers.keys[i]);
		}

		if (self.free_body) {
			t.allocator.free(self.req.bd.?);
		}

		self.req.deinit(t.allocator);
		t.allocator.destroy(self.req);

		self.res.deinit(t.allocator);
		t.allocator.destroy(self.res);

		self.arena.deinit();


		if (self.parsed_response) |*pr| {
			pr.headers.deinit();
			t.allocator.free(pr.raw);
			if (pr.json_value) |*jv| {
				jv.deinit();
			}
		}
	}

	pub fn url(self: *Self, u: []const u8) void {
		self.req.url = httpz.Url.parse(u);
	}

	pub fn param(self: *Self, name: []const u8, value: []const u8) void {
		// This is a big ugly, but the Param structure is optimized for how the router
		// works, so we don't have a clean API for setting 1 key=value pair. We'll
		// just dig into the internals instead
		var p = &self.req.params;
		p.names[p.len] = name;
		p.values[p.len] = value;
		p.len += 1;
	}

	pub fn query(self: *Self, name: []const u8, value: []const u8) void {
		self.req.qs_read = true;
		self.req.qs.add(name, value);
	}

	pub fn header(self: *Self, name: []const u8, value: []const u8) void {
		const lower = t.allocator.alloc(u8, name.len) catch unreachable;
		_ = std.ascii.lowerString(lower, name);
		self.req.headers.add(lower, value);
	}

	pub fn body(self: *Self, bd: []const u8) void {
		self.req.bd_read = true;
		self.req.bd = bd;
	}

	pub fn json(self: *Self, value: anytype) void {
		var arr = std.ArrayList(u8).init(t.allocator);
		defer arr.deinit();

		std.json.stringify(value, .{}, arr.writer()) catch unreachable;

		const bd = t.allocator.alloc(u8, arr.items.len) catch unreachable;
		std.mem.copy(u8, bd, arr.items);
		self.free_body = true;
		self.body(bd);
	}

	pub fn expectStatus(self: Self, expected: u16) !void {
		try t.expectEqual(expected, self.res.status);
	}

	pub fn expectBody(self: *Self, expected: []const u8) !void {
		const pr = try self.parseResponse();
		try t.expectString(expected, pr.body);
	}

	pub fn expectJson(self: *Self, expected: anytype) !void {
		var arr = std.ArrayList(u8).init(t.allocator);
		defer arr.deinit();

		const json_options = .{.string = .{.String = .{.escape_solidus = false}}};
		try std.json.stringify(expected, json_options, arr.writer());

		try self.expectHeader("Content-Type", "application/json");
		try self.expectBody(arr.items);
	}

	pub fn expectHeader(self: *Self, name: []const u8, expected: []const u8) !void {
		const pr = try self.parseResponse();
		try t.expectString(expected, pr.headers.get(name).?);
	}

	pub fn expectHeaderCount(self: *Self, expected: u32) !void {
		const pr = try self.parseResponse();
		try t.expectEqual(expected, pr.headers.count());
	}

	pub fn getJson(self: *Self) !std.json.Value {
		var pr = try self.parseResponse();
		if (pr.json_value) |jv| return jv.root;

		var parser = std.json.Parser.init(t.allocator, false);
		defer parser.deinit();
		pr.json_value = (try parser.parse(pr.body));
		self.parsed_response = pr;
		return pr.json_value.?.root;
	}

	pub fn parseResponse(self: *Self) !Response {
		if (self.parsed_response) |r| return r;

		var stream = t.Stream.init();
		defer stream.deinit();
		try self.res.write(stream);

		const data = stream.received.items;

		// data won't outlive this function, we want our Response to take ownership
		// of the full body, since it needs to reference parts of it.
		const raw = t.allocator.alloc(u8, data.len) catch unreachable;
		std.mem.copy(u8, raw, data);

		var status: u16 = 0;
		var header_length: usize = 0;
		var headers = std.StringHashMap([]const u8).init(t.allocator);

		var it = std.mem.split(u8, raw, "\r\n");
		if (it.next()) |line| {
			header_length = line.len + 2;
			status = try std.fmt.parseInt(u16, line[9..], 10);
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

		const pr = Response{
			.raw = raw,
			.status = status,
			.headers = headers,
			.json_value = null,
			.body = raw[header_length..],
		};

		self.parsed_response = pr;
		return pr;
	}
};

test "testing: params" {
	var ht = init(.{});
	defer ht.deinit();

	ht.param("id", "over9000");
	try t.expectString("over9000", ht.req.params.get("id").?);
	try t.expectEqual(@as(?[]const u8, null), ht.req.params.get("other"));
}

test "testing: query" {
	var ht = init(.{});
	defer ht.deinit();

	ht.query("search", "tea");
	ht.query("category", "447");

	const query = try ht.req.query();
	try t.expectString("tea", query.get("search").?);
	try t.expectString("447", query.get("category").?);
	try t.expectEqual(@as(?[]const u8, null), query.get("other"));
}

test "testing: empty query" {
	var ht = init(.{});
	defer ht.deinit();

	const query = try ht.req.query();
	try t.expectEqual(@as(usize, 0), query.len);
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
	try t.expectEqual(@as(?[]const u8, null), ht.req.headers.get("other"));
}

test "testing: body" {
	var ht = init(.{});
	defer ht.deinit();

	ht.body("the body");
	try t.expectString("the body", (try ht.req.body()).?);
}

test "testing: json" {
	var ht = init(.{});
	defer ht.deinit();

	ht.json(.{.over = 9000});
	try t.expectString("{\"over\":9000}", (try ht.req.body()).?);
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
	try ht.res.json(.{.tea = "keemun"});

	try ht.expectStatus(201);
	try ht.expectJson(.{.tea = "keemun"});
}

test "testing: getJson" {
	var ht = init(.{});
	defer ht.deinit();

	ht.res.status = 201;
	try ht.res.json(.{.tea = "silver needle"});

	try ht.expectStatus(201);
	const json = try ht.getJson();
	try t.expectString("silver needle", json.Object.get("tea").?.String);
}

test "testing: parseResponse" {
	var ht = init(.{});
	defer ht.deinit();
	ht.res.status = 201;
	try ht.res.json(.{.tea = 33});

	try ht.expectStatus(201);
	const res = try ht.parseResponse();
	try t.expectEqual(@as(u16, 201), res.status);
	try t.expectEqual(@as(usize, 2), res.headers.count());
}
