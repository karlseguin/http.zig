const std = @import("std");

const t = @import("t.zig");
const httpz = @import("httpz.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

pub const Action = *const fn(req: *Request, res: *Response) anyerror!void;

// Our router is generic. This is to help us test so that we can create "routes"
// to integers, and then assert that we routed to the right integer (which is
// a lot easier than testing that we routed to the correct Action). However, in
// real life, we always expected this to be a Router(Action).

pub fn Router(comptime A: type) type {
	return struct {
		_allocator: Allocator,
		_get: RoutePart(A),
		_put: RoutePart(A),
		_post: RoutePart(A),
		_head: RoutePart(A),
		_patch: RoutePart(A),
		_delete: RoutePart(A),
		_options: RoutePart(A),

		const Self = @This();

		pub fn init(allocator: Allocator) !Self {
			return Self{
				._allocator = allocator,
				._get = try RoutePart(A).init(allocator),
				._head = try RoutePart(A).init(allocator),
				._post = try RoutePart(A).init(allocator),
				._put = try RoutePart(A).init(allocator),
				._patch = try RoutePart(A).init(allocator),
				._delete = try RoutePart(A).init(allocator),
				._options = try RoutePart(A).init(allocator),
			};
		}

		pub fn deinit(self: *Self) void {
			self._get.deinit();
			self._post.deinit();
			self._put.deinit();
			self._delete.deinit();
			self._patch.deinit();
			self._head.deinit();
			self._options.deinit();
		}

		pub fn route(self: *Self, method: httpz.Method, url: []const u8) ?A {
			return switch (method) {
				httpz.Method.GET => getRoute(A, &self._get, url),
				httpz.Method.POST => getRoute(A, &self._post, url),
				httpz.Method.PUT => getRoute(A, &self._put, url),
				httpz.Method.DELETE => getRoute(A, &self._delete, url),
				httpz.Method.PATCH => getRoute(A, &self._patch, url),
				httpz.Method.HEAD => getRoute(A, &self._head, url),
				httpz.Method.OPTIONS => getRoute(A, &self._options, url),
			};
		}

		pub fn get(self: *Self, path: []const u8, action: A) !void {
			try addRoute(A, self._allocator, &self._get, path, action);
		}
		pub fn put(self: *Self, path: []const u8, action: A) !void {
			try addRoute(A, self._allocator, &self._put, path, action);
		}
		pub fn post(self: *Self, path: []const u8, action: A) !void {
			try addRoute(A, self._allocator, &self._post, path, action);
		}
		pub fn head(self: *Self, path: []const u8, action: A) !void {
			try addRoute(A, self._allocator, &self._head, path, action);
		}
		pub fn patch(self: *Self, path: []const u8, action: A) !void {
			try addRoute(A, self._allocator, &self._patch, path, action);
		}
		pub fn delete(self: *Self, path: []const u8, action: A) !void {
			try addRoute(A, self._allocator, &self._delete, path, action);
		}
		pub fn option(self: *Self, path: []const u8, action: A) !void {
			try addRoute(A, self._allocator, &self._options, path, action);
		}
	};
}

pub fn RoutePart(comptime A: type) type {
	return struct{
		action: ?A,
		parts: StringHashMap(RoutePart(A)),

		const Self = @This();

		pub fn init(allocator: Allocator) !Self {
			return Self{
				.action = null,
				.parts = StringHashMap(RoutePart(A)).init(allocator),
			};
		}

		pub fn deinit(self: *Self) void {
			var it = self.parts.valueIterator();
			while (it.next()) |part| {
				part.deinit();
			}
			self.parts.deinit();
		}
	};
}

fn addRoute(comptime A: type, allocator: Allocator, root: *RoutePart(A), url: []const u8, action: A) !void {
	if (url.len == 0 or (url.len == 1 and url[0] == '/')) {
		root.action = action;
		return;
	}

	var normalized = url;
	if (normalized[0] == '/') {
		normalized = normalized[1..];
	}
	if (normalized[normalized.len - 1] == '/') {
		normalized = normalized[0..normalized.len - 1];
	}


	var route_part = root;
	var it = std.mem.split(u8, normalized, "/");
	while (it.next()) |part| {
		if (part.len == 0) continue;
		var gop = try route_part.parts.getOrPut(part);
		if (gop.found_existing) {
			route_part = gop.value_ptr;
		} else {
			route_part = gop.value_ptr;
			route_part.action = null;
			route_part.parts = StringHashMap(RoutePart(A)).init(allocator);
		}
	}
	route_part.action = action;
}

fn getRoute(comptime A: type, root: *RoutePart(A), url: []const u8) ?A {
	if (url.len == 0 or (url.len == 1 and url[0] == '/')) {
		return root.action;
	}

	var normalized = url;
	if (normalized[0] == '/') {
		normalized = normalized[1..];
	}
	if (normalized[normalized.len - 1] == '/') {
		normalized = normalized[0..normalized.len - 1];
	}


	var route_part = root;
	var it = std.mem.split(u8, normalized, "/");
	while (it.next()) |part| {
		if (route_part.parts.getPtr(part)) |child| {
			route_part = child;
		} else {
			return null;
		}
	}
	return route_part.action;
}

test "route: root" {
	var router = try Router(u32).init(t.allocator);
	defer router.deinit();
	try router.get("/", 1);
	try router.put("/", 2);
	try router.post("", 3);

	try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "").?);
	try t.expectEqual(@as(u32, 2), router.route(httpz.Method.PUT, "").?);
	try t.expectEqual(@as(u32, 3), router.route(httpz.Method.POST, "").?);

	try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "/").?);
	try t.expectEqual(@as(u32, 2), router.route(httpz.Method.PUT, "/").?);
	try t.expectEqual(@as(u32, 3), router.route(httpz.Method.POST, "/").?);

	try t.expectEqual(@as(?u32, null), router.route(httpz.Method.GET, "/other"));
	try t.expectEqual(@as(?u32, null), router.route(httpz.Method.DELETE, "/"));
}


test "route: static" {
	var router = try Router(u32).init(t.allocator);
	defer router.deinit();
	try router.get("hello/world", 1);
	try router.get("/over/9000/", 2);

	// all trailing/leading slash combinations
	try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "hello/world").?);
	try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "/hello/world").?);
	try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "hello/world/").?);
	try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "/hello/world/").?);

	// all trailing/leading slash combinations
	try t.expectEqual(@as(u32, 2), router.route(httpz.Method.GET, "over/9000").?);
	try t.expectEqual(@as(u32, 2), router.route(httpz.Method.GET, "/over/9000").?);
	try t.expectEqual(@as(u32, 2), router.route(httpz.Method.GET, "over/9000/").?);
	try t.expectEqual(@as(u32, 2), router.route(httpz.Method.GET, "/over/9000").?);

	try t.expectEqual(@as(?u32, null), router.route(httpz.Method.GET, "/over/9000!"));
	try t.expectEqual(@as(?u32, null), router.route(httpz.Method.PUT, "/over/9000"));
}
