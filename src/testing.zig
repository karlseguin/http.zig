// Helpers for application developers to be able to mock
// request and parse responses
const std = @import("std");
const t = @import("t.zig");
const httpz = @import("httpz.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub fn init(config: httpz.Config) Testing {
	var arena = t.allocator.create(std.heap.ArenaAllocator) catch unreachable;
	arena.* = std.heap.ArenaAllocator.init(t.allocator);

	var req = t.allocator.create(httpz.Request) catch unreachable;
	req.init(t.allocator, arena.allocator(), config.request) catch unreachable;
	req.url = httpz.Url.parse("/");

	var res = t.allocator.create(httpz.Response) catch unreachable;
	res.init(t.allocator, arena.allocator(), config.response) catch unreachable;

	return Testing{
		.req = req,
		.res = res,
		._arena = arena,
		.arena = arena.allocator(),
	};
}

pub const Testing = struct {
	_arena: *std.heap.ArenaAllocator,
	req: *httpz.Request,
	res: *httpz.Response,
	arena: std.mem.Allocator,
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

		self._arena.deinit();
		t.allocator.destroy(self._arena);

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
		// This is ugly, but the Param structure is optimized for how the router
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
		if (self.free_body) {
			t.allocator.free(self.req.bd.?);
		}

		var arr = ArrayList(u8).init(t.allocator);
		defer arr.deinit();

		std.json.stringify(value, .{}, arr.writer()) catch unreachable;

		const bd = t.allocator.alloc(u8, arr.items.len) catch unreachable;
		@memcpy(bd, arr.items);
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
		const pr = try self.parseResponse();

		try self.expectHeader("Content-Type", "application/json");

		var jc = JsonComparer.init(self.arena);
		const diffs = try jc.compare(expected, pr.body);
		if (diffs.items.len == 0) {
			return;
		}

		for (diffs.items, 0..) |diff, i| {
			std.debug.print("\n==Difference #{d}==\n", .{i+1});
			std.debug.print("  {s}: {s}\n  Left: {s}\n  Right: {s}\n", .{ diff.path, diff.err, diff.a, diff.b});
		}
		return error.JsonNotEqual;
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
		self.res.stream = stream;
		try self.res.write();

		const data = stream.received.items;

		// data won't outlive this function, we want our Response to take ownership
		// of the full body, since it needs to reference parts of it.
		const raw = t.allocator.alloc(u8, data.len) catch unreachable;
		@memcpy(raw, data);

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

const JsonComparer = struct {
	allocator: Allocator,

	const Self = @This();

	const Diff = struct {
		err: []const u8,
		path: []const u8,
		a: []const u8,
		b: []const u8,
	};

	fn init(allocator: Allocator) Self {
		return .{
			.allocator = allocator,
		};
	}

	// We compare by getting the string representation of a and b
	// and then parsing it into a std.json.ValueTree, which we can compare
	// Either a or b might already be serialized JSON string.
	fn compare(self: *Self, a: anytype, b: anytype) !ArrayList(Diff) {
		const allocator = self.allocator;
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

		var a_parser = std.json.Parser.init(allocator, false);
		const a_tree = try a_parser.parse(a_bytes);

		var b_parser = std.json.Parser.init(allocator, false);
		const b_tree = try b_parser.parse(b_bytes);

		var diffs = ArrayList(Diff).init(allocator);
		var path = ArrayList([]const u8).init(allocator);
		try self.compareValue(a_tree.root, b_tree.root, &diffs, &path);
		return diffs;
	}

	fn compareValue(self: *Self, a: std.json.Value, b: std.json.Value, diffs: *ArrayList(Diff), path: *ArrayList([]const u8)) !void {
		const allocator = self.allocator;

		if (!std.mem.eql(u8, @tagName(a), @tagName(b))) {
			diffs.append(self.diff("types don't match", path, @tagName(a), @tagName(b))) catch unreachable;
			return;
		}

		switch (a) {
			.Null => {},
			.Bool => {
				if (a.Bool != b.Bool) {
					diffs.append(self.diff("not equal", path, self.format(a.Bool), self.format(b.Bool))) catch unreachable;
				}
			},
			.Integer => {
				if (a.Integer != b.Integer) {
					diffs.append(self.diff("not equal", path, self.format(a.Integer), self.format(b.Integer))) catch unreachable;
				}
			},
			.Float => {
				if (a.Float != b.Float) {
					diffs.append(self.diff("not equal", path, self.format(a.Float), self.format(b.Float))) catch unreachable;
				}
			},
			.NumberString => {
				if (!std.mem.eql(u8, a.NumberString, b.NumberString)) {
					diffs.append(self.diff("not equal", path, a.NumberString, b.NumberString)) catch unreachable;
				}
			},
			.String => {
				if (!std.mem.eql(u8, a.String, b.String)) {
					diffs.append(self.diff("not equal", path, a.String, b.String)) catch unreachable;
				}
			},
			.Array => {
				const a_len = a.Array.items.len;
				const b_len = b.Array.items.len;
				if (a_len != b_len) {
					diffs.append(self.diff("array length", path, self.format(a_len), self.format(b_len))) catch unreachable;
					return;
				}
				for (a.Array.items, b.Array.items, 0..) |a_item, b_item, i| {
					try path.append(try std.fmt.allocPrint(allocator, "{d}", .{i}));
					try self.compareValue(a_item, b_item, diffs, path);
					_ = path.pop();
				}
			},
			.Object => {
				var it = a.Object.iterator();
				while (it.next()) |entry| {
					const key = entry.key_ptr.*;
					try path.append(key);
					if (b.Object.get(key)) |b_item| {
						try self.compareValue(entry.value_ptr.*, b_item, diffs, path);
					} else {
						diffs.append(self.diff("field missing", path, key, "")) catch unreachable;
					}
					_ = path.pop();
				}
			},
		}
	}

	fn diff(self: *Self, err: []const u8, path: *ArrayList([]const u8), a_rep: []const u8, b_rep: []const u8) Diff {
		const full_path = std.mem.join(self.allocator, ".", path.items) catch unreachable;
		return .{
			.a = a_rep,
			.b = b_rep,
			.err = err,
			.path = full_path,
		};
	}

	fn stringify(self: *Self, value: anytype) ![]const u8 {
		var arr = ArrayList(u8).init(self.allocator);
		try std.json.stringify(value, .{}, arr.writer());
		return arr.items;
	}

	fn format(self: *Self, value: anytype) []const u8 {
		return std.fmt.allocPrint(self.allocator, "{}", .{value}) catch unreachable;
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
	try t.expectString("silver needle", json.Object.get("tea").?.String);
}

test "testing: parseResponse" {
	var ht = init(.{});
	defer ht.deinit();
	ht.res.status = 201;
	try ht.res.json(.{.tea = 33}, .{});

	try ht.expectStatus(201);
	const res = try ht.parseResponse();
	try t.expectEqual(@as(u16, 201), res.status);
	try t.expectEqual(@as(usize, 2), res.headers.count());
}
