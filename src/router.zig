const std = @import("std");

const t = @import("t.zig");
const httpz = @import("httpz.zig");
const Params = @import("params.zig").Params;
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
		_get: Part(A),
		_put: Part(A),
		_post: Part(A),
		_head: Part(A),
		_patch: Part(A),
		_delete: Part(A),
		_options: Part(A),

		const Self = @This();

		pub fn init(allocator: Allocator) !Self {
			return Self{
				._allocator = allocator,
				._get = try Part(A).init(allocator),
				._head = try Part(A).init(allocator),
				._post = try Part(A).init(allocator),
				._put = try Part(A).init(allocator),
				._patch = try Part(A).init(allocator),
				._delete = try Part(A).init(allocator),
				._options = try Part(A).init(allocator),
			};
		}

		pub fn deinit(self: *Self) void {
			const allocator = self._allocator;
			self._get.deinit(allocator);
			self._post.deinit(allocator);
			self._put.deinit(allocator);
			self._delete.deinit(allocator);
			self._patch.deinit(allocator);
			self._head.deinit(allocator);
			self._options.deinit(allocator);
		}

		pub fn route(self: *Self, method: httpz.Method, url: []u8, params: *Params) ?A {
			return switch (method) {
				httpz.Method.GET => getRoute(A, &self._get, url, params),
				httpz.Method.POST => getRoute(A, &self._post, url, params),
				httpz.Method.PUT => getRoute(A, &self._put, url, params),
				httpz.Method.DELETE => getRoute(A, &self._delete, url, params),
				httpz.Method.PATCH => getRoute(A, &self._patch, url, params),
				httpz.Method.HEAD => getRoute(A, &self._head, url, params),
				httpz.Method.OPTIONS => getRoute(A, &self._options, url, params),
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

pub fn Part(comptime A: type) type {
	return struct{
		action: ?A,
		glob: ?*Part(A),
		glob_all: bool,
		param_part: ?*Part(A),
		param_names: ?[][]const u8,
		parts: StringHashMap(Part(A)),

		const Self = @This();

		pub fn init(allocator: Allocator) !Self {
			return Self{
				.glob = null,
				.glob_all = false,
				.action = null,
				.param_part = null,
				.param_names = null,
				.parts = StringHashMap(Part(A)).init(allocator),
			};
		}

		pub fn clear(self: *Self, allocator: Allocator) void {
			self.glob = null;
			self.glob_all = false;
			self.action = null;
			self.param_part = null;
			self.param_names = null;
			self.parts = StringHashMap(Part(A)).init(allocator);
		}

		pub fn deinit(self: *Self, allocator: Allocator) void {
			var it = self.parts.valueIterator();
			while (it.next()) |part| {
				part.deinit(allocator);
			}
			self.parts.deinit();

			if (self.param_part) |part| {
				part.deinit(allocator);
				allocator.destroy(part);
			}

			if (self.param_names) |names| {
				allocator.free(names);
			}

			if (self.glob) |glob| {
				glob.deinit(allocator);
				allocator.destroy(glob);
			}
		}
	};
}

fn addRoute(comptime A: type, allocator: Allocator, root: *Part(A), url: []const u8, action: A) !void {
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

	var param_count: usize = 0;
	var param_name_collector: [Params.MAX][]const u8 = undefined;

	var route_part = root;
	var it = std.mem.split(u8, normalized, "/");
	while (it.next()) |part| {
		if (part[0] == ':') {
			param_name_collector[param_count] = part[1..];
			param_count += 1;
			if (route_part.param_part) |child| {
				route_part = child;
			} else {
				const child = try allocator.create(Part(A));
				child.clear(allocator);
				route_part.param_part = child;
				route_part = child;
			}
		} else if (part.len == 1 and part[0] == '*') {
			// if this route_part didn't already have an action, then this glob also
			// includes it
			if (route_part.action == null) {
				route_part.action = action;
			}

			if (route_part.glob) |child| {
				route_part = child;
			} else {
				const child = try allocator.create(Part(A));
				child.clear(allocator);
				route_part.glob = child;
				route_part = child;
			}
		} else {
			var gop = try route_part.parts.getOrPut(part);
			if (gop.found_existing) {
				route_part = gop.value_ptr;
			} else {
				route_part = gop.value_ptr;
				route_part.clear(allocator);
			}
		}
	}

	if (param_count > 0) {
		const param_names = try allocator.alloc([]const u8, param_count);
		for (0..param_count) |i| {
			param_names[i] = param_name_collector[i];
		}

		route_part.param_names = param_names;
	}

	// if the route ended with a '*' (importantly, as opposed to a '*/') then
	// this is a "glob all" route will. Important, use "url" and not "normalized"
	// since normalized stripped out the trailing / (if any), which is important
	// here
	route_part.glob_all = url[url.len - 1] == '*';

	route_part.action = action;
}

fn getRoute(comptime A: type, root: *Part(A), url: []u8, params: *Params) ?A {
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
	_ = std.ascii.lowerString(normalized, normalized);

	var route_part = root;

	var glob_all: ?*Part(A) = null;
	var it = std.mem.split(u8, normalized, "/");
	while (it.next()) |part| {
		// the most specific "glob_all" route we find, which is the one most deeply
		// nested, is the one we'll use in case there are no other matches.
		if (route_part.glob_all) {
			glob_all = route_part;
		}

		if (route_part.parts.getPtr(part)) |child| {
			route_part = child;
		} else if (route_part.param_part) |child| {
			params.addValue(part);
			route_part = child;
		} else if (route_part.glob) |child| {
			route_part = child;
		} else {
			params.len = 0;
			if (glob_all) |fallback| {
				return fallback.action;
			}
			return null;
		}
	}

	if (route_part.action) |action| {
		if (route_part.param_names) |names| {
			params.addNames(names);
		} else {
			params.len = 0;
		}
		return action;
	}

	params.len = 0;
	if (glob_all) |fallback| {
		return fallback.action;
	}
	return null;
}

test "route: root" {
	var params = try Params.init(t.allocator);
	defer params.deinit();

	var router = try Router(u32).init(t.allocator);
	defer router.deinit();
	try router.get("/", 1);
	try router.put("/", 2);
	try router.post("", 3);

	var _urls = [_][]const u8{"/", "/other"};
	var urls = t.mutableStrings(_urls[0..]);
	defer t.clearMutableStrings(urls);

	try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "", &params).?);
	try t.expectEqual(@as(u32, 2), router.route(httpz.Method.PUT, "", &params).?);
	try t.expectEqual(@as(u32, 3), router.route(httpz.Method.POST, "", &params).?);

	try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, urls[0], &params).?);
	try t.expectEqual(@as(u32, 2), router.route(httpz.Method.PUT, urls[0], &params).?);
	try t.expectEqual(@as(u32, 3), router.route(httpz.Method.POST, urls[0], &params).?);

	try t.expectEqual(@as(?u32, null), router.route(httpz.Method.GET, urls[1], &params));
	try t.expectEqual(@as(?u32, null), router.route(httpz.Method.DELETE, urls[0], &params));
}

test "route: static" {
	var params = try Params.init(t.allocator);
	defer params.deinit();

	var router = try Router(u32).init(t.allocator);
	defer router.deinit();
	try router.get("hello/world", 1);
	try router.get("/over/9000/", 2);

	{
		var _urls = [_][]const u8{"hello/world", "/hello/world", "hello/world/", "/hello/world/", "HELLO/WORLD", "/HELLO/worlD", "HELLO/WORLD/", "/HELLO/WORLD/"};
		var urls = t.mutableStrings(_urls[0..]);
		defer t.clearMutableStrings(urls);

		// all trailing/leading slash combinations
		for (urls) |url| {
			try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, url, &params).?);
		}
	}

	{
		var _urls = [_][]const u8{"over/9000", "/over/9000", "over/9000/", "/over/9000/"};
		var urls = t.mutableStrings(_urls[0..]);
		defer t.clearMutableStrings(urls);

		// all trailing/leading slash combinations
		for (urls) |url| {
			try t.expectEqual(@as(u32, 2), router.route(httpz.Method.GET, url, &params).?);

			// different method
			try t.expectEqual(@as(?u32, null), router.route(httpz.Method.PUT, url, &params));
		}
	}

	{
		// random not found
		var _urls = [_][]const u8{"over/9000!", "over/ 9000"};
		var urls = t.mutableStrings(_urls[0..]);
		defer t.clearMutableStrings(urls);
		for (urls) |url| {
			try t.expectEqual(@as(?u32, null), router.route(httpz.Method.GET, url, &params));
		}
	}
}

test "route: params" {
	var params = try Params.init(t.allocator);
	defer params.deinit();

	var router = try Router(u32).init(t.allocator);
	defer router.deinit();
	try router.get("/:p1", 1);
	try router.get("/users/:p2", 2);
	try router.get("/users/:p2/fav", 3);
	try router.get("/users/:p2/like", 4);
	try router.get("/users/:p2/fav/:p3", 5);
	try router.get("/users/:p2/like/:p3", 6);

	{
		// root param
		var url = t.mutableString("info");
		defer t.clearMutableString(url);

		try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, url, &params).?);
		try t.expectEqual(@as(usize, 1), params.len);
		try t.expectString("info", params.get("p1").?);
	}

	{
		// nested param
		var url = t.mutableString("/USERS/33");
		defer t.clearMutableString(url);

		params.reset();
		try t.expectEqual(@as(u32, 2), router.route(httpz.Method.GET, url, &params).?);
		try t.expectEqual(@as(usize, 1), params.len);
		try t.expectString("33", params.get("p2").?);
	}

	{
		// nested param with statix suffix
		var url1 = t.mutableString("/users/9/fav");
		var url2 = t.mutableString("/users/9/like");
		defer t.clearMutableString(url1);
		defer t.clearMutableString(url2);

		params.reset();
		try t.expectEqual(@as(u32, 3), router.route(httpz.Method.GET, url1, &params).?);
		try t.expectEqual(@as(usize, 1), params.len);
		try t.expectString("9", params.get("p2").?);

		params.reset();
		try t.expectEqual(@as(u32, 4), router.route(httpz.Method.GET, url2, &params).?);
		try t.expectEqual(@as(usize, 1), params.len);
		try t.expectString("9", params.get("p2").?);
	}

	{
		// nested params
		var url1 = t.mutableString("/users/u1/fav/blue");
		var url2 = t.mutableString("/users/u3/like/Tea");
		defer t.clearMutableString(url1);
		defer t.clearMutableString(url2);

		params.reset();
		try t.expectEqual(@as(u32, 5), router.route(httpz.Method.GET, url1, &params).?);
		try t.expectEqual(@as(usize, 2), params.len);
		try t.expectString("u1", params.get("p2").?);
		try t.expectString("blue", params.get("p3").?);

		params.reset();
		try t.expectEqual(@as(u32, 6), router.route(httpz.Method.GET, url2, &params).?);
		try t.expectEqual(@as(usize, 2), params.len);
		try t.expectString("u3", params.get("p2").?);
		try t.expectString("tea", params.get("p3").?);
	}

	{
		// not_found
		var url1 = t.mutableString("/users/u1/other");
		var url2 = t.mutableString("/users/u1/favss/blue");
		defer t.clearMutableString(url1);
		defer t.clearMutableString(url2);

		params.reset();
		try t.expectEqual(@as(?u32, null), router.route(httpz.Method.GET, url1, &params));
		try t.expectEqual(@as(usize, 0), params.len);

		try t.expectEqual(@as(?u32, null), router.route(httpz.Method.GET, url2, &params));
		try t.expectEqual(@as(usize, 0), params.len);
	}
}

test "route: glob" {
	var params = try Params.init(t.allocator);
	defer params.deinit();

	var router = try Router(u32).init(t.allocator);
	defer router.deinit();
	try router.get("/*", 1);
	try router.get("/users/*", 2);
	try router.get("/users/*/test", 3);
	try router.get("/users/other/test", 4);

	{
		// root glob
		var _urls = [_][]const u8{"/anything", "/this/could/be/anything", "/"};
		var urls = t.mutableStrings(_urls[0..]);
		defer t.clearMutableStrings(urls);
		for (urls) |url| {
			try t.expectEqual(@as(?u32, 1), router.route(httpz.Method.GET, url, &params));
			try t.expectEqual(@as(usize, 0), params.len);
		}
	}

	{
		// nest glob
		var _urls = [_][]const u8{"/users/", "/users", "/users/hello", "/users/could/be/anything"};
		var urls = t.mutableStrings(_urls[0..]);
		defer t.clearMutableStrings(urls);
		for (urls) |url| {
			try t.expectEqual(@as(?u32, 2), router.route(httpz.Method.GET, url, &params));
			try t.expectEqual(@as(usize, 0), params.len);
		}
	}

	{
		// nest glob specific
		var _urls = [_][]const u8{"/users/hello/test", "/users/x/test"};
		var urls = t.mutableStrings(_urls[0..]);
		defer t.clearMutableStrings(urls);
		for (urls) |url| {
			try t.expectEqual(@as(?u32, 3), router.route(httpz.Method.GET, url, &params));
			try t.expectEqual(@as(usize, 0), params.len);
		}
	}

	{
		// nest glob specific
		var url = t.mutableString("/users/other/test");
		defer t.clearMutableString(url);
		try t.expectEqual(@as(?u32, 4), router.route(httpz.Method.GET, url, &params));
		try t.expectEqual(@as(usize, 0), params.len);
	}
}

// TODO: this functionality isn't implemented because I can't think of a way
// to do it which isn't relatively expensive (e.g. recursively or keeping a
// stack of (a) parts and (b) url segments and trying to rematch every possible
// combination of param + part)...and I don't know that this use-case is really
// common.

// test "route: ambiguous params" {
// 	var params = try Params.init(t.allocator);
// 	defer params.deinit();

// 	var router = try Router(u32).init(t.allocator);
// 	defer router.deinit();
// 	try router.get("/:any/users", 1);
// 	try router.get("/hello/users/test", 2);

// 	{
// 		try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "/x/users", &params).?);
// 		try t.expectEqual(@as(usize, 1), params.len);
// 		try t.expectString("x", params.get("any").?);

// 		params.reset();
// 		try t.expectEqual(@as(u32, 2), router.route(httpz.Method.GET, "/hello/users/test", &params).?);
// 		try t.expectEqual(@as(usize, 0), params.len);

// 		params.reset();
// 		try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "/hello/users", &params).?);
// 		try t.expectEqual(@as(usize, 1), params.len);
// 		try t.expectString("hello", params.get("any").?);
// 	}
// }
