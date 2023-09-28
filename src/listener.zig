const std = @import("std");
const t = @import("t.zig");
const builtin = @import("builtin");
const httpz = @import("httpz.zig");

const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;
const Conn = if (builtin.is_test) t.Connection else std.net.StreamServer.Connection;

const os = std.os;
const net = std.net;
const log = std.log.scoped(.httpz);

pub fn listen(comptime S: type, httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: Config) !void {
	var pool = try Pool(S).init(httpz_allocator, app_allocator, server, &config);
	defer pool.deinit();

	var socket = net.StreamServer.init(.{
		.reuse_address = true,
		.kernel_backlog = 1024,
	});
	defer socket.deinit();

	const listen_port = config.port.?;
	const listen_address = config.address.?;
	try socket.listen(net.Address.parseIp(listen_address, listen_port) catch unreachable);

	// TODO: Broken on darwin:
	// https://github.com/ziglang/zig/issues/17260
	// if (@hasDecl(os.TCP, "NODELAY")) {
	// 	try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
	// }
	try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));

	while (true) {
		if (socket.accept()) |conn| {
			const c: Conn = if (comptime builtin.is_test) undefined else conn;
			pool.handle(c) catch |err| {
				conn.stream.close();
				log.err("internal failure to handle connection {}", .{err});
			};
		} else |err| {
			log.err("failed to accept connection {}", .{err});
		}
	}
}

const Queue = std.DoublyLinkedList(Conn);

fn Pool(comptime S: type) type {
	return struct {
		// pending connections that need to be picked up by a worker
		queue: Queue,

		// protect the queue
		mutex: Thread.Mutex,

		// the pool's side of a socketpair, used to communicate with the workers
		streams: []Stream,

		// the worker thread
		threads: []Thread,

		// the workers
		workers: []Worker(S),

		// the index of the nexst worker to get a connection
		next_worker: usize,

		httpz_allocator: Allocator,

		const Self = @This();

		fn init(httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: *const Config) !*Self {
			const worker_count = config.pool.count orelse (Thread.getCpuCount() catch 2);

			var streams = try httpz_allocator.alloc(Stream, worker_count);
			errdefer httpz_allocator.free(streams);

			var threads = try httpz_allocator.alloc(Thread, worker_count);
			errdefer httpz_allocator.free(threads);

			var workers = try httpz_allocator.alloc(Worker(S), worker_count);
			errdefer httpz_allocator.free(workers);

			var pool = try httpz_allocator.create(Self);
			pool.* = .{
				.mutex = .{},
				.queue = .{},
				.streams = streams,
				.threads = threads,
				.workers = workers,
				.next_worker = 0,
				.httpz_allocator = httpz_allocator,
			};
			errdefer httpz_allocator.destroy(pool);

			var spawned: usize = 0;
			errdefer pool.stop(spawned);

			const dummy_address = std.net.Address.initIp4([_]u8{127, 0, 0, 127}, 9999);

			for (0..worker_count) |i| {
				var pair: [2]c_int = undefined;
				const rc = std.c.socketpair(std.os.AF.LOCAL, std.os.SOCK.STREAM, 0, &pair);
				if (rc != 0) {
					log.err("std.c.socketpair failure: {any}\n", .{std.os.errno(rc)});
					return error.SetupError;
				}
				const pool_control = Stream{.handle = pair[0]};
				const worker_control = Conn{.stream = .{.handle = pair[1]}, .address = dummy_address};
				streams[i] = pool_control;

				workers[i] = try Worker(S).init(httpz_allocator, app_allocator, server, config, pool);
				workers[i].newConn(worker_control);
				errdefer workers[i].deinit();

				threads[i] = try Thread.spawn(.{}, Worker(S).run, .{&workers[i]});
				spawned += 1;
			}

			return pool;
		}

		fn deinit(self: *Self) void {
			const allocator = self.httpz_allocator;
			self.stop(self.threads.len);
			allocator.free(self.streams);
			allocator.free(self.threads);
			allocator.free(self.workers);
			allocator.destroy(self);
		}

		fn stop(self: *Self, spawned: usize) void {
			for (0..spawned) |i| {
				self.streams[i].close();
				self.threads[i].join();
				self.workers[i].deinit();
			}
		}

		fn handle(self: *Self, conn: Conn) !void {
			const notify = &[1]u8{0};
			var node = try self.httpz_allocator.create(Queue.Node);
			errdefer self.httpz_allocator.destroy(node);

			node.data = conn;
			self.mutex.lock();
			self.queue.append(node);
			self.mutex.unlock();

			const next_worker = self.next_worker;
			try self.streams[next_worker].writeAll(notify);
			self.next_worker = (next_worker + 1) % self.streams.len;
		}
	};
}

pub fn Worker(comptime S: type) type {
	return struct {
		server: S,

		pool: *Pool(S),

		// all data we can allocate upfront and re-use from request to request
		req_state: Request.State,

		// all data we can allocate upfront and re-use from request ot request (for the response)
		res_state: Response.State,

		// every request and response will be given an allocator from this arena
		arena: *ArenaAllocator,

		// allocator for httpz internal allocations
		httpz_allocator: Allocator,

		// the number of connections this working is currently monitoring
		len: usize,

		// an array of Conn objects that we're currently monitoring
		conns: []Conn,

		// an array of pollfd objects, corresponding to `connections`.
		// separate array so we can pass this as-is to os.poll
		poll_fds: []os.pollfd,

		const Self = @This();

		pub fn init(httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: *const Config, pool: *Pool(S)) !Self {
			const arena = try httpz_allocator.create(ArenaAllocator);
			arena.* = ArenaAllocator.init(app_allocator);
			errdefer httpz_allocator.destroy(arena);

			var req_state = try Request.State.init(httpz_allocator, config.request);
			errdefer req_state.deinit(httpz_allocator);

			var res_state = try Response.State.init(httpz_allocator, config.response);
			errdefer req_state.deinit(httpz_allocator);

			const max_conns = config.pool.worker_max_conn orelse 512;

			var conns = try httpz_allocator.alloc(Conn, max_conns);
			errdefer httpz_allocator.free(conns);

			var poll_fds = try httpz_allocator.alloc(os.pollfd, max_conns);
			errdefer httpz_allocator.free(poll_fds);

			return .{
				.len = 0,
				.pool = pool,
				.arena = arena,
				.server = server,
				.poll_fds = poll_fds,
				.req_state = req_state,
				.res_state = res_state,
				.httpz_allocator = httpz_allocator,
				.conns = conns,
			};
		}

		pub fn deinit(self: *Self) void {
			const httpz_allocator = self.httpz_allocator;

			for (self.conns[0..self.len]) |conn| {
				conn.stream.close();
			}
			httpz_allocator.free(self.conns);
			httpz_allocator.free(self.poll_fds);

			self.req_state.deinit(httpz_allocator);
			self.res_state.deinit(httpz_allocator);

			self.arena.deinit();
			httpz_allocator.destroy(self.arena);
		}

		fn run(self: *Self) void {
			std.os.maybeIgnoreSigpipe();

			var len = self.len;
			var has_pending = false;
			var pool_buf: [8]u8 = undefined;

			const conns = self.conns;
			const max_len = conns.len;
			const poll_fds = self.poll_fds;

			while (true) {
				if (has_pending and len < max_len) {
					self.len = len;
					switch (self.acceptConn()) {
						.none => has_pending = false,
						.one => {
							len += 1;
							has_pending = false;
						},
						.many => len += 1,  // keep has_pending = true
					}
				}

				_ = os.poll(poll_fds[0..len], -1) catch |err| {
					log.err("failed to poll sockets: {any}", .{err});
					std.time.sleep(std.time.ns_per_s);
					continue;
				};

				pool_event: {
					// our special socketpair is always at index 0, if we have data here, it
					// means the pool is trying to tell us something
					const pool_event = poll_fds[0].revents;
					if (pool_event == 0) {
						break :pool_event;
					}

					if (pool_event & os.POLL.HUP == os.POLL.HUP) {
						// other end closed, indicating that we're shutting down
						self.len = len;
						return;
					}

					if (pool_event & os.POLL.IN == os.POLL.IN) {
						const n = conns[0].stream.read(&pool_buf) catch return;
						if (n == 0) return;
						has_pending = true;
					} else {
						log.info("unexpected poll event on socketpair: {d}\n", .{pool_event});
					}
				}

				// skip 1, since we just handled it above
				var i: usize = 1;
				while (i < len) {
					if (poll_fds[i].revents == 0) {
						i += 1;
						continue;
					}

					const conn = conns[i];
					if (self.handleRequest(conn) == true) {
						i += 1;
					} else {
						// this connection is closed (or in some invalid state)
						conn.stream.close();

						// we "remove" this item from our list by swaping the last item in its place
						len -= 1;
						if (i != len) {
							conns[i] = conns[len];
							poll_fds[i] = poll_fds[len];
						}
						// don't increment i, since it now contains the previous last
					}
				}
			}
		}

		fn acceptConn(self: *Self) AcceptResult {
			const pool = self.pool;
			pool.mutex.lock();
			if (pool.queue.popFirst()) |node| {
				const state = if (pool.queue.len == 0) AcceptResult.one else AcceptResult.many;
				pool.mutex.unlock();
				const conn = node.data;
				self.httpz_allocator.destroy(node);
				self.newConn(conn);
				return state;
			}
			pool.mutex.unlock();
			return .none;
		}

		fn newConn(self: *Self, conn: Conn) void {
			const len = self.len;
			self.conns[len] = conn;
			self.poll_fds[len] = os.pollfd{
				.revents = 0,
				.events = os.POLL.IN,
				.fd = conn.stream.handle,
			};
			self.len = len + 1;
		}

		pub fn handleRequest(self: *Self, conn: Conn) bool {
			const stream = conn.stream;

			const arena = self.arena;
			const server = self.server;

			var req_state = &self.req_state;
			var res_state = &self.res_state;

			req_state.reset();
			res_state.reset();

			defer _ = arena.reset(.free_all);

			var aa = arena.allocator();
			var res = Response.init(aa, res_state, stream);

			var req = Request.parse(aa, req_state, conn) catch |err| {
				switch (err) {
					error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
						res.status = 400;
						res.body = "Invalid Request";
					},
					error.HeaderTooBig => {
						res.status = 431;
						res.body = "Request header is too big";
					},
					else => return false,
				}
				res.write() catch {};
				return false;
			};

			if (!server.handle(&req, &res)) {
				return false;
			}
			req.drain() catch return false;
			return true;
		}
	};
}

const AcceptResult = enum {
	none,
	one,
	many,
};
