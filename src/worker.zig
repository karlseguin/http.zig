const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz.zig");
const Config = httpz.Config;
const Request = httpz.Request;
const Response = httpz.Response;

const Conn = @import("conn.zig").Conn;
const BufferPool = @import("buffer.zig").Pool;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Stream = std.net.Stream;
const NetConn = std.net.StreamServer.Connection;

const os = std.os;
const net = std.net;
const log = std.log.scoped(.httpz);

pub fn Worker(comptime S: type) type {
	return struct {
		server: S,

		// KQueue or Epoll, depending on the platform
		loop: Loop,

		// all data we can allocate upfront and re-use from request ot request (for the response)
		res_state: Response.State,

		// every request and response will be given an allocator from this arena
		arena: *ArenaAllocator,

		// allocator for httpz internal allocations
		httpz_allocator: Allocator,

		// Manager of connections. This includes a list of active connections the
		// worker is responsible for, as well as buffer connections can use to
		// get larger []u8, and a pool of re-usable connection objects to reduce
		// dynamic allocations needed for new requests.
		manager: Manager,

		// the maximum connection a worker should manage, we won't accept more than this
		max_conn: usize,

		keepalive_timeout: u32,

		config: *const Config,

		const Self = @This();

		const Loop = switch (builtin.os.tag) {
			.macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue,
			.linux => EPoll,
			else => @compileError("not supported"),
		};

		pub fn init(httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: *const Config) !Self {
			const arena = try httpz_allocator.create(ArenaAllocator);
			arena.* = ArenaAllocator.init(app_allocator);
			errdefer httpz_allocator.destroy(arena);

			var res_state = try Response.State.init(httpz_allocator, config.response);
			errdefer res_state.deinit(httpz_allocator);

			const loop = try Loop.init();
			errdefer loop.deinit();

			const manager = try Manager.init(httpz_allocator, config);
			errdefer manager.deinit();

			return .{
				.loop = loop,
				.arena = arena,
				.config = config,
				.server = server,
				.manager = manager,
				.res_state = res_state,
				.httpz_allocator = httpz_allocator,
				.max_conn = config.workers.max_conn orelse 512,
				.keepalive_timeout = config.keepalive.timeout orelse 4294967295,
			};
		}

		pub fn deinit(self: *Self) void {
			const httpz_allocator = self.httpz_allocator;

			self.manager.deinit();
			self.res_state.deinit(httpz_allocator);

			self.arena.deinit();

			httpz_allocator.destroy(self.arena);
			self.loop.deinit();
		}

		pub fn run(self: *Self, listener: os.fd_t, signal: os.fd_t) void {
			std.os.maybeIgnoreSigpipe();
			const manager = &self.manager;

			self.loop.add(listener, 0) catch |err| {
				log.err("Failed to add monitor to listening socket: {}", .{err});
				return;
			};

			self.loop.add(signal, 1) catch |err| {
				log.err("Failed to add monitor to signal pipe: {}", .{err});
				return;
			};

			const keepalive_timeout = self.keepalive_timeout;

			while (true) {
				var it = self.loop.wait() catch |err| {
					log.err("Failed to wait on events: {}", .{err});
					std.time.sleep(std.time.ns_per_s);
					continue;
				};
				const now = std.time.microTimestamp();

				while (it.next()) |data| {
					if (data == 0) {
						self.accept(listener, now) catch |err| {
							log.err("Failed to accept connection: {}", .{err});
							std.time.sleep(std.time.ns_per_s);
						};
						continue;
					}

					if (data == 1) {
						// our control signal, we're being told to stop,
						return;
					}

					const conn: *align(8) Conn = @ptrFromInt(data);
					var will_close = (now - conn.last_request) > keepalive_timeout;

					switch (self.handleRequest(conn, will_close)) {
						.need_more_data => {},
						.failure => will_close = true,
						.success => {
							conn.req_state.reset();
							conn.last_request = now;
						},
					}

					if (will_close) {
						manager.close(conn);
					}
				}
			}
		}

		fn accept(self: *Self, listener: os.fd_t, now: i64) !void {
			const max_conn = self.max_conn;

			var manager = &self.manager;
			var len = manager.len;

			while (len < max_conn) {
				var address: std.net.Address = undefined;
				var address_len: os.socklen_t = @sizeOf(std.net.Address);

				const socket = os.accept(listener, &address.any, &address_len, os.SOCK.CLOEXEC) catch |err| {
					// Wouldblock is normal here, as another thread might have accepted
					return if (err == error.WouldBlock) {} else err;
				};
				errdefer os.close(socket);

				{
					// set non blocking
					const flags = try os.fcntl(socket, os.F.GETFL, 0);
					_ = try os.fcntl(socket, os.F.SETFL, flags | os.SOCK.NONBLOCK);
				}

				var conn = try manager.new();
				conn.last_request = now;
				conn.stream = .{.handle = socket};
				conn.address = address;

				try self.loop.add(socket, @intFromPtr(conn));
				len += 1;
			}
		}

		const HandleResult = enum {
			need_more_data,
			success,
			failure,
		};

		pub fn handleRequest(self: *Self, conn: *Conn, will_close: bool) HandleResult {
			const stream = conn.stream;
			const done = conn.req_state.parse(stream) catch |err| switch (err) {
				error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
					stream.writeAll(errorResponse(400, "Invalid Request")) catch {};
					return .failure;
				},
				error.HeaderTooBig => {
					stream.writeAll(errorResponse(431, "Request header is too big")) catch {};
					return .failure;
				},
				else => return .failure,
			};

			if (done == false) {
				return .need_more_data;
			}

			const arena = self.arena;
			const server = self.server;
			var res_state = &self.res_state;

			res_state.reset();

			defer _ = arena.reset(.free_all);

			const aa = arena.allocator();

			var req = Request.init(aa, conn, will_close);
			var res = Response.init(aa, res_state, conn.stream);

			if (!server.handle(&req, &res)) {
				return .failure;
			}
			return .success;
		}
	};
}

fn errorResponse(comptime status: u16, comptime body: []const u8) []const u8 {
	return std.fmt.comptimePrint(
		"HTTP/1.1 {d}\r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}",
		.{status, body.len, body}
	);
}

const KQueue = struct {
	q: i32,
	change_count: usize,
	change_buffer: [8]Kevent,
	event_list: [32]Kevent,

	const Kevent = std.os.Kevent;

	fn init() !KQueue {
		return .{
			.q = try std.os.kqueue(),
			.change_count = 0,
			.change_buffer = undefined,
			.event_list = undefined,
		};
	}

	fn deinit(self: KQueue) void {
		std.os.close(self.q);
	}

	fn add(self: *KQueue, fd: os.fd_t, data: usize) !void {
		return self.change(.{
			.ident = @intCast(fd),
			.filter = os.system.EVFILT_READ,
			.flags = os.system.EV_ADD | os.system.EV_ENABLE,
			.fflags = 0,
			.data = 0,
			.udata = data,
		});
	}

	fn change(self: *KQueue, event: Kevent) !void {
		var change_count = self.change_count;
		var change_buffer = &self.change_buffer;

		if (change_count == change_buffer.len) {
			// calling this with an empty event_list will return immediate
			_ = try std.os.kevent(self.q, change_buffer, &[_]Kevent{}, null);
			change_count = 0;
		}
		change_buffer[change_count] = event ;
		self.change_count = change_count + 1;
	}

	fn wait(self: *KQueue) !Iterator {
		const event_list = &self.event_list;
		const event_count = try std.os.kevent(self.q, self.change_buffer[0..self.change_count], event_list, null);
		self.change_count = 0;

		return .{
			.index = 0,
			.events = event_list[0..event_count],
		};
	}

	const Iterator = struct {
		index: usize,
		events: []Kevent,

		fn next(self: *Iterator) ?usize{
			const index = self.index;
			const events = self.events;
			if (index == events.len) {
				return null;
			}
			self.index = index + 1;
			return self.events[index].udata;
		}
	};
};

const EPoll = struct {
	q: i32,
	event_list: [32]EpollEvent,

	const EpollEvent = std.os.linux.epoll_event;

	fn init() !EPoll {
		return .{
			.event_list = undefined,
			.q = try std.os.epoll_create1(0),
		};
	}

	fn deinit(self: EPoll) void {
		std.os.close(self.q);
	}

	fn add(self: *EPoll, fd: os.fd_t, user_data: usize) !void {
		var event = os.linux.epoll_event{
			.events = os.linux.EPOLL.IN,
			.data = .{.ptr = user_data}
		};
		return std.os.epoll_ctl(self.q, os.linux.EPOLL.CTL_ADD, fd, &event);
	}

	fn wait(self: *EPoll) !Iterator {
		const event_list = &self.event_list;
		const event_count = std.os.epoll_wait(self.q, event_list, -1);
		return .{
			.index = 0,
			.events = event_list[0..event_count],
		};
	}

	const Iterator = struct {
		index: usize,
		events: []EpollEvent,

		fn next(self: *Iterator) ?usize{
			const index = self.index;
			const events = self.events;
			if (index == events.len) {
				return null;
			}
			self.index = index + 1;
			return self.events[index].data.ptr;
		}
	};
};

const Manager = struct {
	// Double linked list of Conn a worker is currently managing. The head of the
	// list has the "oldest" connection. Age, e.g. "oldest", is measured by time
	// of last request, not when the connection was first established. This is
	// important for keepalive. We keep them in this order so that we can quickly
	// scan for timed out connections.
	list: List(Conn),

	// # of active connections we're managing. This is the length of our list.
	len: usize,

	// A pool of Conn objects. The pool maintains a configured min # of these.
	conn_pool: ConnPool,

	// Request and response processing may require larger buffers than the static
	// buffered of our req/res states. The BufferPool has larger pre-allocated
	// buffers that can be used and, when empty or when a larger buffer is needed,
	// will do dynamic allocation
	buffer_pool: *BufferPool,

	allocator: Allocator,

	fn init(allocator: Allocator, config: *const Config) !Manager {
		const buffer_pool = try allocator.create(BufferPool);
		errdefer allocator.destroy(buffer_pool);

		const large_buffer_count = config.workers.large_buffer_count orelse 8;
		const large_buffer_size = config.workers.large_buffer_size orelse config.request.max_body_size orelse 65536;
		buffer_pool.* = try BufferPool.init(allocator, large_buffer_count, large_buffer_size);
		errdefer buffer_pool.deinit();

		const conn_pool = try ConnPool.init(allocator, buffer_pool, config);

		return .{
			.len = 0,
			.list = .{},
			.conn_pool = conn_pool,
			.allocator = allocator,
			.buffer_pool = buffer_pool,
		};
	}

	pub fn deinit(self: *Manager) void {
		const allocator = self.allocator;

		var conn = self.list.head;
		while (conn) |c| {
			c.stream.close();
			conn = c.next;

			c.deinit(allocator);
			self.conn_pool.mem_pool.destroy(c);
		}

		self.conn_pool.deinit();

		self.buffer_pool.deinit();
		allocator.destroy(self.buffer_pool);
	}

	pub fn new(self: *Manager) !*Conn {
		const conn = try self.conn_pool.acquire();
		self.list.insert(conn);
		self.len += 1;
		return conn;
	}

	pub fn close(self: *Manager, conn: *Conn) void {
		conn.stream.close();
		self.list.remove(conn);
		self.conn_pool.release(conn);
		self.len -= 1;
	}
};

const ConnPool = struct {
	conns: []*Conn,
	available: usize,
	allocator: Allocator,
	config: *const Config,
	buffer_pool: *BufferPool,
	mem_pool: std.heap.MemoryPool(Conn),

	fn init(allocator: Allocator, buffer_pool: *BufferPool, config: *const Config) !ConnPool {
		const min = config.workers.min_conn orelse config.workers.max_conn orelse 32;

		var conns = try allocator.alloc(*Conn, min);
		errdefer allocator.free(conns);

		var mem_pool = std.heap.MemoryPool(Conn).init(allocator);

		var initialized: usize = 0;
		errdefer {
			for (0..initialized) |i| {
				conns[i].deinit(allocator);
				mem_pool.destroy(conns[i]);
			}
		}

		for (0..min) |i| {
			const conn = try mem_pool.create();
			errdefer mem_pool.destroy(conn);

			conn.* = .{
				.last_request = 0,
				.stream = undefined,
				.address = undefined,
				.req_state = try Request.State.init(allocator, buffer_pool, &config.request),
			};
			conns[i] = conn;
			initialized += 1;
		}

		return .{
			.conns = conns,
			.config = config,
			.available = min,
			.allocator = allocator,
			.mem_pool = mem_pool,
			.buffer_pool = buffer_pool,
		};
	}

	fn deinit(self: *ConnPool) void {
		const allocator = self.allocator;
		for (self.conns) |conn| {
			conn.deinit(allocator);
			self.mem_pool.destroy(conn);
		}
		allocator.free(self.conns);
		self.mem_pool.deinit();
	}

	fn acquire(self: *ConnPool) !*Conn {
		const available = self.available;

		if (available > 0) {
			const index = available - 1;
			self.available = index;
			return self.conns[index];
		}

		const conn = try self.mem_pool.create();
		errdefer self.mem_pool.destroy(conn);
		conn.req_state = try Request.State.init(self.allocator, self.buffer_pool, &self.config.request);
		return conn;
	}

	fn release(self: *ConnPool, conn: *Conn) void {
		const conns = self.conns;
		const available = self.available;
		if (available == conns.len) {
			conn.deinit(self.allocator);
			self.mem_pool.destroy(conn);
			return;
		}

		conn.last_request = 0;
		conn.req_state.reset();
		conn.stream = undefined;
		conn.address = undefined;
		conns[available] = conn;
		self.available = available + 1;
	}
};

pub fn List(comptime T: type) type {
	return struct {
		len: usize = 0,
		head: ?*T = null,
		tail: ?*T = null,

		const Self = @This();

		pub fn insert(self: *Self, node: *T) void {
			if (self.tail) |tail| {
				tail.next = node;
				node.prev = tail;
				self.tail = node;
			} else {
				self.head = node;
				self.tail = node;
			}
			self.len += 1;
			node.next = null;
		}

		pub fn remove(self: *Self, node: *T) void {
			if (node.prev) |prev| {
				prev.next = node.next;
			} else {
				self.head = node.next;
			}

			if (node.next) |next| {
				next.prev = node.prev;
			} else {
				self.tail = node.prev;
			}
			self.len -= 1;
		}
	};
}

const t = @import("t.zig");
test "ConnPool" {
	var bp = try BufferPool.init(t.allocator, 2, 64);
	defer bp.deinit();

	var p = try ConnPool.init(t.allocator, &bp, &.{
		.workers = .{.min_conn = 2},
		.request = .{.buffer_size = 64},
	});
	defer p.deinit();

	const s1 = try p.acquire();
	const s2 = try p.acquire();
	const s3 = try p.acquire();

	try t.expectEqual(true, s1.req_state.buf.ptr != s2.req_state.buf.ptr);
	try t.expectEqual(true, s1.req_state.buf.ptr != s3.req_state.buf.ptr);
	try t.expectEqual(true, s2.req_state.buf.ptr != s3.req_state.buf.ptr);

	p.release(s2);
	const s4 = try p.acquire();
	try t.expectEqual(true, s4.req_state.buf.ptr == s2.req_state.buf.ptr);

	p.release(s1);
	p.release(s3);
	p.release(s4);
}

test "Conn: List" {
	var list = List(TestNode){};
	try expectList(&.{}, list);

	var n1 = TestNode{.id = 1};
	list.insert(&n1);
	try expectList(&.{1}, list);

	list.remove(&n1);
	try expectList(&.{}, list);

	var n2 = TestNode{.id = 2};
	list.insert(&n2);
	list.insert(&n1);
	try expectList(&.{2, 1}, list);

	var n3 = TestNode{.id = 3};
	list.insert(&n3);
	try expectList(&.{2, 1, 3}, list);

	list.remove(&n1);
	try expectList(&.{2, 3}, list);

	list.insert(&n1);
	try expectList(&.{2, 3, 1}, list);

	list.remove(&n2);
	try expectList(&.{3, 1}, list);

	list.remove(&n1);
	try expectList(&.{3}, list);

	list.remove(&n3);
	try expectList(&.{}, list);
}

const TestNode = struct {
	id: i32,
	next: ?*TestNode = null,
	prev: ?*TestNode = null,
};

fn expectList(expected: []const i32, list: List(TestNode)) !void {
	if (expected.len == 0) {
		try t.expectEqual(null, list.head);
		try t.expectEqual(null, list.tail);
		return;
	}

	var i: usize = 0;
	var next = list.head;
	while (next) |node| {
		try t.expectEqual(expected[i], node.id);
		i += 1;
		next = node.next;
	}
	try t.expectEqual(expected.len, i);

	i = expected.len;
	var prev = list.tail;
	while (prev) |node| {
		i -= 1;
		try t.expectEqual(expected[i], node.id);
		prev = node.prev;
	}
	try t.expectEqual(0, i);
}
