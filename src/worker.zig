const std = @import("std");
const t = @import("t.zig");
const httpz = @import("httpz.zig");

const response = @import("response.zig");
const Config = @import("config.zig").Config;
const Request = @import("request.zig").Request;
const Response = httpz.Response;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Stream = std.net.Stream;
const NetConn = std.net.StreamServer.Connection;

const os = std.os;
const net = std.net;
const log = std.log.scoped(.httpz);

const KeepaliveConn = struct {
	conn: NetConn,
	last_request: i64,
};

pub fn Worker(comptime S: type) type {
	return struct {
		server: S,

		// all data we can allocate upfront and re-use from request to request
		req_state: Request.State,

		// all data we can allocate upfront and re-use from request ot request (for the response)
		res_state: Response.State,

		// every request and response will be given an allocator from this arena
		arena: *ArenaAllocator,

		// allocator for httpz internal allocations
		httpz_allocator: Allocator,

		// the number of connections this worker is currently monitoring
		len: usize,

		// an array of Conn objects that we're currently monitoring
		conns: []KeepaliveConn,

		// an array of pollfd objects, corresponding to `connections`.
		// separate array so we can pass this as-is to os.poll
		poll_fds: []os.pollfd,

		keepalive_timeout: u32,

		const Self = @This();

		pub fn init(httpz_allocator: Allocator, app_allocator: Allocator, server: S, config: *const Config) !Self {
			const arena = try httpz_allocator.create(ArenaAllocator);
			arena.* = ArenaAllocator.init(app_allocator);
			errdefer httpz_allocator.destroy(arena);

			var req_state = try Request.State.init(httpz_allocator, config.request);
			errdefer req_state.deinit(httpz_allocator);

			var res_state = try Response.State.init(httpz_allocator, config.response);
			errdefer res_state.deinit(httpz_allocator);

			const max_conns = config.pool.worker_max_conn orelse 512;

			const conns = try httpz_allocator.alloc(KeepaliveConn, max_conns);
			errdefer httpz_allocator.free(conns);

			const poll_fds = try httpz_allocator.alloc(os.pollfd, max_conns);
			errdefer httpz_allocator.free(poll_fds);

			return .{
				.len = 0,
				.arena = arena,
				.conns = conns,
				.server = server,
				.poll_fds = poll_fds,
				.req_state = req_state,
				.res_state = res_state,
				.httpz_allocator = httpz_allocator,
				.keepalive_timeout = config.keepalive.timeout orelse 4294967295,
			};
		}

		pub fn deinit(self: *Self) void {
			const httpz_allocator = self.httpz_allocator;

			// 0 is the listener socket, we aren't responsible for that
			for (self.conns[1..self.len]) |ka_conn| {
				ka_conn.conn.stream.close();
			}
			httpz_allocator.free(self.conns);
			httpz_allocator.free(self.poll_fds);

			self.req_state.deinit(httpz_allocator);
			self.res_state.deinit(httpz_allocator);

			self.arena.deinit();
			httpz_allocator.destroy(self.arena);
		}

		pub fn run(self: *Self, listener: *net.StreamServer) void {
			std.os.maybeIgnoreSigpipe();

			const conns = self.conns;
			const max_len = conns.len;
			const poll_fds = self.poll_fds;
			const keepalive_timeout = self.keepalive_timeout;

			poll_fds[0] = .{
				.revents = 0,
				.fd = listener.sockfd.?,
				.events = os.POLL.IN,
			};

			const listener_poll = &poll_fds[0];

			var len : usize = 1;
			while (true) {
				_ = os.poll(poll_fds[0..len], -1) catch |err| {
					log.err("failed to poll sockets: {any}", .{err});
					std.time.sleep(std.time.ns_per_s);
					continue;
				};

				const now = std.time.microTimestamp();

				// our special socketpair is always at index 0, if we have data here, it
				// means the pool is trying to tell us something
				if (listener_poll.revents != 0) accept: {
					while (len < max_len) {
						if (listener.accept()) |conn| {
							poll_fds[len] = .{
								.revents = 0,
								.events = os.POLL.IN,
								.fd = conn.stream.handle,
							};
							conns[len] = .{.conn = conn, .last_request = now};
							len += 1;
						} else |err| {
							if (err != error.WouldBlock) {
								log.err("accept error: {any}", .{err});
							}
							break: accept;
						}
					}
				}


				// skip 1, since we just handled it above
				var i: usize = 1;
				while (i < len) {
					const kconn = &conns[i];
					var will_close = (now - kconn.last_request) > keepalive_timeout;
					if (poll_fds[i].revents != 0) {
						if (self.handleRequest(kconn.conn, will_close)) {
							kconn.last_request = now;
						} else {
							will_close = true;
						}
					}

					if (will_close) {
						kconn.conn.stream.close();
						// we "remove" this item from our list by swaping the last item in its place
						len -= 1;
						self.len = len;
						if (i != len) {
							conns[i] = conns[len];
							poll_fds[i] = poll_fds[len];
						}
						// don't increment i, since it now contains the previous last
					} else {
						i += 1;
					}
				}
			}
		}

		pub fn handleRequest(self: *Self, conn: NetConn, will_close: bool) bool {
			const stream = conn.stream;

			const arena = self.arena;
			const server = self.server;

			var req_state = &self.req_state;
			var res_state = &self.res_state;

			req_state.reset();
			res_state.reset();

			defer _ = arena.reset(.free_all);

			const aa = arena.allocator();
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

			req.keepalive = !will_close;
			if (!server.handle(&req, &res)) {
				return false;
			}
			req.drain() catch return false;
			return true;
		}
	};
}
