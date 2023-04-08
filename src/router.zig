const std = @import("std");

const t = @import("t.zig");
const httpz = @import("httpz.zig");
const Params = @import("params.zig").Params;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

pub fn Config(comptime G: type, comptime R: type) type {
	const Dispatcher = httpz.Dispatcher(G, R);
	return struct {
		dispatcher: ?Dispatcher = null,
	};
}

pub fn Router(comptime G: type, comptime R: type) type {
	const Action = httpz.Action(R);
	const Dispatcher = httpz.Dispatcher(G, R);
	const DispatchableAction = httpz.DispatchableAction(G, R);

	return struct {
		_allocator: Allocator,
		_get: Part(DispatchableAction),
		_put: Part(DispatchableAction),
		_post: Part(DispatchableAction),
		_head: Part(DispatchableAction),
		_patch: Part(DispatchableAction),
		_delete: Part(DispatchableAction),
		_options: Part(DispatchableAction),
		_default_dispatcher: Dispatcher,

		const Self = @This();

		pub fn init(allocator: Allocator, default_dispatcher: Dispatcher) !Self {
			return Self{
				._allocator = allocator,
				._default_dispatcher = default_dispatcher,
				._get = try Part(DispatchableAction).init(allocator),
				._head = try Part(DispatchableAction).init(allocator),
				._post = try Part(DispatchableAction).init(allocator),
				._put = try Part(DispatchableAction).init(allocator),
				._patch = try Part(DispatchableAction).init(allocator),
				._delete = try Part(DispatchableAction).init(allocator),
				._options = try Part(DispatchableAction).init(allocator),
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

		pub fn route(self: Self, method: httpz.Method, url: []const u8, params: *Params) ?DispatchableAction {
			return switch (method) {
				httpz.Method.GET => getRoute(DispatchableAction, self._get, url, params),
				httpz.Method.POST => getRoute(DispatchableAction, self._post, url, params),
				httpz.Method.PUT => getRoute(DispatchableAction, self._put, url, params),
				httpz.Method.DELETE => getRoute(DispatchableAction, self._delete, url, params),
				httpz.Method.PATCH => getRoute(DispatchableAction, self._patch, url, params),
				httpz.Method.HEAD => getRoute(DispatchableAction, self._head, url, params),
				httpz.Method.OPTIONS => getRoute(DispatchableAction, self._options, url, params),
			};
		}

		pub fn get(self: *Self, path: []const u8, action: Action, config: Config(G, R)) void {
			self.tryGet(path, action, config) catch @panic("failed to create route");
		}
		pub fn tryGet(self: *Self, path: []const u8, action: Action, config: Config(G, R)) !void {
			const da = DispatchableAction{
				.action = action,
				.dispatcher = config.dispatcher orelse self._default_dispatcher,
			};
			try addRoute(DispatchableAction, self._allocator, &self._get, path, da);
		}

		pub fn put(self: *Self, path: []const u8, action: Action, config: Config(G, R)) void {
			self.tryPut(path, action, config) catch @panic("failed to create route");
		}
		pub fn tryPut(self: *Self, path: []const u8, action: Action, config: Config(G, R)) !void {
			const da = DispatchableAction{
				.action = action,
				.dispatcher = config.dispatcher orelse self._default_dispatcher,
			};
			try addRoute(DispatchableAction, self._allocator, &self._put, path, da);
		}

		pub fn post(self: *Self, path: []const u8, action: Action, config: Config(G, R)) void {
			self.tryPost(path, action, config) catch @panic("failed to create route");
		}
		pub fn tryPost(self: *Self, path: []const u8, action: Action, config: Config(G, R)) !void {
			const da = DispatchableAction{
				.action = action,
				.dispatcher = config.dispatcher orelse self._default_dispatcher,
			};
			try addRoute(DispatchableAction, self._allocator, &self._post, path, da);
		}

		pub fn head(self: *Self, path: []const u8, action: Action, config: Config(G, R)) void {
			self.tryHead(path, action, config) catch @panic("failed to create route");
		}
		pub fn tryHead(self: *Self, path: []const u8, action: Action, config: Config(G, R)) !void {
			const da = DispatchableAction{
				.action = action,
				.dispatcher = config.dispatcher orelse self._default_dispatcher,
			};
			try addRoute(DispatchableAction, self._allocator, &self._head, path, da);
		}

		pub fn patch(self: *Self, path: []const u8, action: Action, config: Config(G, R)) void {
			self.tryPatch(path, action, config) catch @panic("failed to create route");
		}
		pub fn tryPatch(self: *Self, path: []const u8, action: Action, config: Config(G, R)) !void {
			const da = DispatchableAction{
				.action = action,
				.dispatcher = config.dispatcher orelse self._default_dispatcher,
			};
			try addRoute(DispatchableAction, self._allocator, &self._patch, path, da);
		}

		pub fn delete(self: *Self, path: []const u8, action: Action, config: Config(G, R)) void {
			self.tryDelete(path, action, config) catch @panic("failed to create route");
		}
		pub fn tryDelete(self: *Self, path: []const u8, action: Action, config: Config(G, R)) !void {
			const da = DispatchableAction{
				.action = action,
				.dispatcher = config.dispatcher orelse self._default_dispatcher,
			};
			try addRoute(DispatchableAction, self._allocator, &self._delete, path, da);
		}

		pub fn option(self: *Self, path: []const u8, action: Action, config: Config(G, R)) void {
			self.tryOption(path, action, config) catch @panic("failed to create route");
		}
		pub fn tryOption(self: *Self, path: []const u8, action: Action, config: Config(G, R)) !void {
			const da = DispatchableAction{
				.action = action,
				.dispatcher = config.dispatcher orelse self._default_dispatcher,
			};
			try addRoute(DispatchableAction, self._allocator, &self._options, path, da);
		}

		pub fn all(self: *Self, path: []const u8, action: Action, config: Config(G, R)) void {
			self.tryAll(path, action, config) catch @panic("failed to create route");
		}
		pub fn tryAll(self: *Self, path: []const u8, action: Action, config: Config(G, R)) !void {
			try self.tryGet(path, action, config);
			try self.tryPut(path, action, config);
			try self.tryPost(path, action, config);
			try self.tryHead(path, action, config);
			try self.tryPatch(path, action, config);
			try self.tryDelete(path, action, config);
			try self.tryOption(path, action, config);
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

	var param_name_collector = std.ArrayList([]const u8).init(allocator);
	defer param_name_collector.deinit();

	var route_part = root;
	var it = std.mem.split(u8, normalized, "/");
	while (it.next()) |part| {
		if (part[0] == ':') {
			try param_name_collector.append(part[1..]);
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

	const param_name_count = param_name_collector.items.len;
	if (param_name_count > 0) {
		const param_names = try allocator.alloc([]const u8, param_name_count);
		for (param_name_collector.items, 0..) |name, i| {
			param_names[i] = name;
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

fn getRoute(comptime A: type, root: Part(A), url: []const u8, params: *Params) ?A {
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

	var r = root;
	var route_part = &r;

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
	var params = try Params.init(t.allocator, 5);
	defer params.deinit(t.allocator);

	var router = Router(void, void).init(t.allocator, testDispatcher1) catch unreachable;
	defer router.deinit();
	router.get("/", testRoute1, .{});
	router.put("/", testRoute2, .{});
	router.post("", testRoute3, .{});
	router.all("/all", testRoute4, .{});

	var urls = .{"/", "/other", "/all"};
	try t.expectEqual(&testRoute1, router.route(httpz.Method.GET, "", &params).?.action);
	try t.expectEqual(&testRoute2, router.route(httpz.Method.PUT, "", &params).?.action);
	try t.expectEqual(&testRoute3, router.route(httpz.Method.POST, "", &params).?.action);

	try t.expectEqual(&testRoute1, router.route(httpz.Method.GET, urls[0], &params).?.action);
	try t.expectEqual(&testRoute2, router.route(httpz.Method.PUT, urls[0], &params).?.action);
	try t.expectEqual(&testRoute3, router.route(httpz.Method.POST, urls[0], &params).?.action);

	try t.expectEqual(@as(?httpz.DispatchableAction(void, void), null), router.route(httpz.Method.GET, urls[1], &params));
	try t.expectEqual(@as(?httpz.DispatchableAction(void, void), null), router.route(httpz.Method.DELETE, urls[0], &params));

	// test "all" route
	inline for (@typeInfo(httpz.Method).Enum.fields) |field| {
		const m = @intToEnum(httpz.Method, field.value);
		try t.expectEqual(&testRoute4, router.route(m, urls[2], &params).?.action);
	}
}

test "route: static" {
	var params = try Params.init(t.allocator, 5);
	defer params.deinit(t.allocator);

	var router = Router(void, void).init(t.allocator, testDispatcher1) catch unreachable;
	defer router.deinit();
	router.get("hello/world", testRoute1, .{});
	router.get("/over/9000/", testRoute2, .{});

	{
		const urls = .{"hello/world", "/hello/world", "hello/world/", "/hello/world/"};
		// all trailing/leading slash combinations
		try t.expectEqual(&testRoute1, router.route(httpz.Method.GET, urls[0], &params).?.action);
		try t.expectEqual(&testRoute1, router.route(httpz.Method.GET, urls[1], &params).?.action);
		try t.expectEqual(&testRoute1, router.route(httpz.Method.GET, urls[2], &params).?.action);
	}

	{
		const urls = .{"over/9000", "/over/9000", "over/9000/", "/over/9000/"};
		// all trailing/leading slash combinations
		inline for (urls) |url| {
			try t.expectEqual(&testRoute2, router.route(httpz.Method.GET, url, &params).?.action);

			// different method
			try t.expectEqual(@as(?httpz.DispatchableAction(void, void), null), router.route(httpz.Method.PUT, url, &params));
		}
	}

	{
		// random not found
		const urls = .{"over/9000!", "over/ 9000"};
		inline for (urls) |url| {
			try t.expectEqual(@as(?httpz.DispatchableAction(void, void), null), router.route(httpz.Method.GET, url, &params));
		}
	}
}

test "route: params" {
	var params = try Params.init(t.allocator, 5);
	defer params.deinit(t.allocator);

	var router = Router(void, void).init(t.allocator, testDispatcher1) catch unreachable;
	defer router.deinit();
	router.get("/:p1", testRoute1, .{});
	router.get("/users/:p2", testRoute2, .{});
	router.get("/users/:p2/fav", testRoute3, .{});
	router.get("/users/:p2/like", testRoute4, .{});
	router.get("/users/:p2/fav/:p3", testRoute5, .{});
	router.get("/users/:p2/like/:p3", testRoute6, .{});

	{
		// root param
		try t.expectEqual(&testRoute1, router.route(httpz.Method.GET, "info", &params).?.action);
		try t.expectEqual(@as(usize, 1), params.len);
		try t.expectString("info", params.get("p1").?);
	}

	{
		// nested param
		params.reset();
		try t.expectEqual(&testRoute2, router.route(httpz.Method.GET, "/users/33", &params).?.action);
		try t.expectEqual(@as(usize, 1), params.len);
		try t.expectString("33", params.get("p2").?);
	}

	{
		// nested param with statix suffix
		params.reset();
		try t.expectEqual(&testRoute3, router.route(httpz.Method.GET, "/users/9/fav", &params).?.action);
		try t.expectEqual(@as(usize, 1), params.len);
		try t.expectString("9", params.get("p2").?);

		params.reset();
		try t.expectEqual(&testRoute4, router.route(httpz.Method.GET, "/users/9/like", &params).?.action);
		try t.expectEqual(@as(usize, 1), params.len);
		try t.expectString("9", params.get("p2").?);
	}

	{
		// nested params
		params.reset();
		try t.expectEqual(&testRoute5, router.route(httpz.Method.GET, "/users/u1/fav/blue", &params).?.action);
		try t.expectEqual(@as(usize, 2), params.len);
		try t.expectString("u1", params.get("p2").?);
		try t.expectString("blue", params.get("p3").?);

		params.reset();
		try t.expectEqual(&testRoute6, router.route(httpz.Method.GET, "/users/u3/like/tea", &params).?.action);
		try t.expectEqual(@as(usize, 2), params.len);
		try t.expectString("u3", params.get("p2").?);
		try t.expectString("tea", params.get("p3").?);
	}

	{
		// not_found
		params.reset();
		try t.expectEqual(@as(?httpz.DispatchableAction(void, void), null), router.route(httpz.Method.GET, "/users/u1/other", &params));
		try t.expectEqual(@as(usize, 0), params.len);

		try t.expectEqual(@as(?httpz.DispatchableAction(void, void), null), router.route(httpz.Method.GET, "/users/u1/favss/blue", &params));
		try t.expectEqual(@as(usize, 0), params.len);
	}
}

test "route: glob" {
	var params = try Params.init(t.allocator, 5);
	defer params.deinit(t.allocator);

	var router = Router(void, void).init(t.allocator, testDispatcher1) catch unreachable;
	defer router.deinit();
	router.get("/*", testRoute1, .{});
	router.get("/users/*", testRoute2, .{});
	router.get("/users/*/test", testRoute3, .{});
	router.get("/users/other/test", testRoute4, .{});

	{
		// root glob
		const urls = .{"/anything", "/this/could/be/anything", "/"};
		inline for (urls) |url| {
			try t.expectEqual(&testRoute1, router.route(httpz.Method.GET, url, &params).?.action);
			try t.expectEqual(@as(usize, 0), params.len);
		}
	}

	{
		// nest glob
		const urls = .{"/users/", "/users", "/users/hello", "/users/could/be/anything"};
		inline for (urls) |url| {
			try t.expectEqual(&testRoute2, router.route(httpz.Method.GET, url, &params).?.action);
			try t.expectEqual(@as(usize, 0), params.len);
		}
	}

	{
		// nest glob specific
		const urls = .{"/users/hello/test", "/users/x/test"};
		inline for (urls) |url| {
			try t.expectEqual(&testRoute3, router.route(httpz.Method.GET, url, &params).?.action);
			try t.expectEqual(@as(usize, 0), params.len);
		}
	}

	{
		// nest glob specific
		try t.expectEqual(&testRoute4, router.route(httpz.Method.GET, "/users/other/test", &params).?.action);
		try t.expectEqual(@as(usize, 0), params.len);
	}
}

// TODO: this functionality isn't implemented because I can't think of a way
// to do it which isn't relatively expensive (e.g. recursively or keeping a
// stack of (a) parts and (b) url segments and trying to rematch every possible
// combination of param + part)...and I don't know that this use-case is really
// common.

// test "route: ambiguous params" {
// 	var params = try Params.init(t.allocator, 5);
// 	defer params.deinit();

// 	var router = Router(u32).init(t.allocator, 9999999) catch unreachable;
// 	defer router.deinit();
// 	router.get("/:any/users", 1, .{});
// 	router.get("/hello/users/test", 2, .{});

// 	{
// 		try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "/x/users", &params));
// 		try t.expectEqual(@as(usize, 1), params.len);
// 		try t.expectString("x", params.get("any"));

// 		params.reset();
// 		try t.expectEqual(@as(u32, 2), router.route(httpz.Method.GET, "/hello/users/test", &params));
// 		try t.expectEqual(@as(usize, 0), params.len);

// 		params.reset();
// 		try t.expectEqual(@as(u32, 1), router.route(httpz.Method.GET, "/hello/users", &params));
// 		try t.expectEqual(@as(usize, 1), params.len);
// 		try t.expectString("hello", params.get("any"));
// 	}
// }

fn testDispatcher1(_: httpz.Action(void), _: *Request, _: *Response) anyerror!void{}
fn testRoute1(_: *Request, _: *Response) anyerror!void {}
fn testRoute2(_: *Request, _: *Response) anyerror!void {}
fn testRoute3(_: *Request, _: *Response) anyerror!void {}
fn testRoute4(_: *Request, _: *Response) anyerror!void {}
fn testRoute5(_: *Request, _: *Response) anyerror!void {}
fn testRoute6(_: *Request, _: *Response) anyerror!void {}
