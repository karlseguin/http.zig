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

		// For reading large bodies
		buffer_pool: *BufferPool,

		// all data we can allocate upfront and re-use from request ot request (for the response)
		res_state: Response.State,

		// every connection gets a state, which are pooled.
		req_state_pool: RequestStatePool,

		// every request and response will be given an allocator from this arena
		arena: *ArenaAllocator,

		// allocator for httpz internal allocations
		httpz_allocator: Allocator,

		// a linked list of Conn objects that we're currently monitoring
		conn_list: Conn.List,

		// the maximum connection a worker should manage, we won't accept more than this
		max_conn: usize,

		// pool for creating Conn
		conn_pool: std.heap.MemoryPool(Conn),

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

			const worker_config = config.workers;

			const buffer_pool = try httpz_allocator.create(BufferPool);
			errdefer httpz_allocator.destroy(buffer_pool);

			const large_buffer_count = worker_config.large_buffer_count orelse 8;
			const large_buffer_size = worker_config.large_buffer_size orelse config.request.max_body_size orelse 65536;
			buffer_pool.* = try BufferPool.init(httpz_allocator, large_buffer_count, large_buffer_size);
			errdefer buffer_pool.deinit();

			const req_state_pool = try RequestStatePool.init(httpz_allocator, buffer_pool, config);
			errdefer req_state_pool.deinit();

			return .{
				.loop = loop,
				.arena = arena,
				.config = config,
				.conn_list = .{},
				.max_conn = worker_config.max_conn orelse 512,
				.conn_pool = std.heap.MemoryPool(Conn).init(httpz_allocator),
				.server = server,
				.res_state = res_state,
				.req_state_pool = req_state_pool,
				.buffer_pool = buffer_pool,
				.httpz_allocator = httpz_allocator,
				.keepalive_timeout = config.keepalive.timeout orelse 4294967295,
			};
		}

		pub fn deinit(self: *Self) void {
			const httpz_allocator = self.httpz_allocator;

			var conn = self.conn_list.head;
			while (conn) |c| {
				c.stream.close();
				conn = c.next;
			}

			self.res_state.deinit(httpz_allocator);

			self.arena.deinit();
			self.conn_pool.deinit();
			self.req_state_pool.deinit();

			self.buffer_pool.deinit();
			httpz_allocator.destroy(self.buffer_pool);

			httpz_allocator.destroy(self.arena);

			self.loop.deinit();
		}

		pub fn run(self: *Self, listener: *net.StreamServer, signal: os.fd_t) void {
			std.os.maybeIgnoreSigpipe();

			self.loop.add(listener.sockfd.?, 0) catch |err| {
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
							conn.reader.reset();
							conn.req_state.reset();
							conn.last_request = now;
						},
					}

					if (will_close) {
						conn.stream.close();
						self.conn_list.remove(conn);
						if (conn.reader.body) |buf| {
							self.buffer_pool.release(buf);
						}
						self.req_state_pool.release(conn.req_state);
						self.conn_pool.destroy(conn);
					}
				}
			}
		}

		fn accept(self: *Self, listener: *net.StreamServer, now: i64) !void {
			var conn_list = &self.conn_list;
			var len = conn_list.len;

			const max_conn = self.max_conn;

			while (len < max_conn) {
				const conn = listener.accept() catch |err| {
					// Wouldblock is normal here, as another thread might have accepted
					return if (err == error.WouldBlock) {} else err;
				};
				errdefer conn.stream.close();

				const stream = conn.stream;
				{
					// set non blocking
					const socket = stream.handle;
					const flags = try os.fcntl(socket, os.F.GETFL, 0);
					_ = try os.fcntl(socket, os.F.SETFL, flags | os.SOCK.NONBLOCK);
				}

				const managed = try self.conn_pool.create();
				errdefer self.conn_pool.destroy(managed);

				const req_state = try self.req_state_pool.acquire();
				errdefer self.req_state_pool.release(req_state);

				managed.* = .{
					.stream = stream,
					.last_request = now,
					.address = conn.address,
					.req_state = req_state,
					.reader = Request.Reader.init(req_state),
				};
				try self.loop.add(conn.stream.handle, @intFromPtr(managed));
				conn_list.insert(managed);
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
			const done = conn.reader.parse(conn.stream) catch |err| switch (err) {
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

// 1 per worker
const RequestStatePool = struct {
	states: []*Request.State,
	available: usize,
	allocator: Allocator,
	buffer_pool: *BufferPool,
	req_config: *const Request.Config,
	state_pool: std.heap.MemoryPool(Request.State),

	fn init(allocator: Allocator, buffer_pool: *BufferPool, config: *const Config) !RequestStatePool {
		const min = config.workers.min_conn orelse config.workers.max_conn orelse 32;

		var states = try allocator.alloc(*Request.State, min);
		errdefer allocator.free(states);

		var state_pool = std.heap.MemoryPool(Request.State).init(allocator);

		var initialized: usize = 0;
		errdefer {
			for (0..initialized) |i| {
				states[i].deinit(allocator);
				state_pool.destroy(states[i]);
			}
		}

		for (0..min) |i| {
			const state = try state_pool.create();
			errdefer state_pool.destroy(state);

			state.* = try Request.State.init(allocator, buffer_pool, &config.request);
			states[i] = state;
			initialized += 1;
		}

		return .{
			.states = states,
			.available = min,
			.allocator = allocator,
			.state_pool = state_pool,
			.buffer_pool = buffer_pool,
			.req_config = &config.request,
		};
	}


	fn deinit(self: *RequestStatePool) void {
		for (self.states) |state| {
			state.deinit(self.allocator);
			self.state_pool.destroy(state);
		}
		self.state_pool.deinit();
	}

	fn acquire(self: *RequestStatePool) !*Request.State {
		const available = self.available;
		if (available > 0) {
			const index = available - 1;
			self.available = index;
			return self.states[index];
		}

		const state = try self.state_pool.create();
		state.* = try Request.State.init(self.allocator, self.buffer_pool, self.req_config);
		return state;
	}

	fn release(self: *RequestStatePool, state: *Request.State) void {
		const states = self.states;
		const available = self.available;
		if (available == states.len) {
			state.deinit(self.allocator);
			self.state_pool.destroy(state);
			return;
		}

		states[available] = state;
		self.available = available + 1;
	}
};
