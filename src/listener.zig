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

	// TODO: I believe this should work, but it currently doesn't on 0.11-dev. Instead I have to
	// hardcode 1 for the setsocopt NODELAY option
	// if (@hasDecl(os.TCP, "NODELAY")) {
	// 	try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
	// }
	try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));

	while (true) {
		if (socket.accept()) |conn| {
			const c: Conn = if (comptime builtin.is_test) undefined else conn;
			pool.handle(c) catch |err| {
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
		running: bool,
		queue: Queue,
		threads: []Thread,
		workers: []Worker(S),
		mutex: Thread.Mutex,
		cond: Thread.Condition,
		httpz_allocator: Allocator,

		const Self = @This();

		fn init(httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: *const Config) !*Self {
			const worker_count = config.pool.count orelse (Thread.getCpuCount() catch 2);

			var threads = try httpz_allocator.alloc(Thread, worker_count);
			errdefer httpz_allocator.free(threads);

			var workers = try httpz_allocator.alloc(Worker(S), worker_count);
			errdefer httpz_allocator.free(workers);

			var pool = try httpz_allocator.create(Self);
			pool.* = .{
				.cond = .{},
				.mutex = .{},
				.queue = .{},
				.running = true,
				.threads = threads,
				.workers = workers,
				.httpz_allocator = httpz_allocator,
			};
			errdefer httpz_allocator.destroy(pool);

			var spawned: usize = 0;
			errdefer pool.stop(spawned);

			for (0..worker_count) |i| {
				workers[i] = try Worker(S).init(httpz_allocator, app_allocator, server, config, pool);
				errdefer workers[i].deinit();

				threads[i] = try Thread.spawn(.{}, Worker(S).run, .{&workers[i]});
				spawned += 1;
			}

			return pool;
		}

		fn deinit(self: *Self) void {
			const allocator = self.httpz_allocator;
			self.stop(self.threads.len);
			allocator.free(self.threads);
			allocator.free(self.workers);
			allocator.destroy(self);
		}

		fn stop(self: *Self, spawned: usize) void {
			self.mutex.lock();
			self.running = false;
			self.mutex.unlock();
			self.cond.broadcast();

			var threads = self.threads;
			var workers = self.workers;
			for (0..spawned) |i| {
				threads[i].join();
				workers[i].deinit();
			}
		}

		fn handle(self: *Self, conn: Conn) !void {
			var node = try self.httpz_allocator.create(Queue.Node);
			node.data = conn;
			self.mutex.lock();
			self.queue.append(node);
			self.mutex.unlock();
			self.cond.signal();
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

			return .{
				.pool = pool,
				.arena = arena,
				.server = server,
				.req_state = req_state,
				.res_state = res_state,
				.httpz_allocator = httpz_allocator,
				.len = 0,
				.conns = try httpz_allocator.alloc(Conn, max_conns),
				.poll_fds = try httpz_allocator.alloc(os.pollfd, max_conns),
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

			const pool = self.pool;
			var mutex = &pool.mutex;
			var queue = &pool.queue;
			const httpz_allocator = self.httpz_allocator;

			mutex.lock();
			while (true) {
				if (queue.popFirst()) |node| {
					mutex.unlock();
					const conn = node.data;
					httpz_allocator.destroy(node);
					if (self.handleRequest(conn)) {
						self.newConn(conn) catch {
							// TODO
							unreachable;
						};
					}
				} else {
					defer mutex.unlock();
					if (pool.running == false) {
						return;
					}
				}
				self.poll();
				mutex.lock();
			}
		}

		fn newConn(self: *Self, conn: Conn) !void {
			const len = self.len;
			self.conns[len] = conn;
			self.poll_fds[len] = os.pollfd{
				.revents = 0,
				.events = os.POLL.IN,
				.fd = conn.stream.handle,
			};
			self.len = len + 1;
		}

		fn poll(self: *Self) void {
			var len = self.len;
			if (len == 0) {
				return;
			}
			var conns = self.conns;
			var poll_fds = self.poll_fds;
			while (true) {
				const is_full = len == conns.len;

				// if our worker is full, we can't accept new connections
				const timeout: i32 = if (is_full) -1 else 10;

				const count = os.poll(poll_fds, timeout) catch {
					unreachable; // TODO;
				};

				if (count == 0) {
					return;
				}

				var i: usize = 0;
				// shrink as we remove items
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
						if (len == 0) {
							self.len = 0;
							return;
						}
						conns[i] = conns[len];
						poll_fds[i] = poll_fds[len];
						// don't increment i, since it now contains the previous last
					}
				}
				self.len = len;
			}
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
