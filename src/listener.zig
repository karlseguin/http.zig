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
		req_state: Request.State,
		res_state: Response.State,
		arena: *ArenaAllocator,
		httpz_allocator: Allocator,

		const Self = @This();

		pub fn init(httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: *const Config, pool: *Pool(S)) !Self {
			const arena = try httpz_allocator.create(ArenaAllocator);
			arena.* = ArenaAllocator.init(app_allocator);
			errdefer httpz_allocator.destroy(arena);

			var req_state = try Request.State.init(httpz_allocator, config.request);
			errdefer req_state.deinit(httpz_allocator);

			var res_state = try Response.State.init(httpz_allocator, config.response);
			errdefer req_state.deinit(httpz_allocator);

			return .{
				.pool = pool,
				.arena = arena,
				.server = server,
				.req_state = req_state,
				.res_state = res_state,
				.httpz_allocator = httpz_allocator,
			};
		}

		pub fn deinit(self: *Self) void {
			const httpz_allocator = self.httpz_allocator;

			self.req_state.deinit(httpz_allocator);
			self.res_state.deinit(httpz_allocator);

			self.arena.deinit();
			httpz_allocator.destroy(self.arena);
		}

		pub fn run(self: *Self) void {
			std.os.maybeIgnoreSigpipe();

			const pool = self.pool;
			var mutex = &pool.mutex;
			var queue = &pool.queue;

			const httpz_allocator = self.httpz_allocator;

			mutex.lock();
			while (true) {
				while (queue.popFirst()) |node| {
					mutex.unlock();
					defer mutex.lock();
					const conn = node.data;
					httpz_allocator.destroy(node);
					self.handleConnection(conn);
				}

				// mutex is locked here, either because there was nothing queue
				// or because the defer inside the while re-locked it after handleConnection
				if (pool.running == false) {
					return;
				}
				pool.cond.wait(mutex);
			}
		}

		pub fn handleConnection(self: *Self, conn: Conn) void {
			const stream = conn.stream;
			defer stream.close();

			const arena = self.arena;
			const server = self.server;

			var req_state = &self.req_state;
			var res_state = &self.res_state;


			while (true) {
				res_state.reset();
				req_state.reset();

				defer _ = arena.reset(.free_all);

				var aa = arena.allocator();
				var res = Response.init(aa, res_state, stream);

				var req = Request.parse(aa, req_state, conn) catch |err| switch (err) {
					error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
						res.status = 400;
						res.body = "Invalid Request";
						res.write() catch {};
						return;
					},
					error.HeaderTooBig => {
						res.status = 431;
						res.body = "Request header is too big";
						res.write() catch {};
						return;
					},
					else => return,
				};


				if (!server.handle(&req, &res)) {
					return;
				}
				req.drain() catch return;
			}
		}
	};
}
