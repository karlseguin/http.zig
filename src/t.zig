// Internal helpers used by this library
// If you're looking for helpers to help you mock/test
// httpz.Request and httpz.Response, checkout testing.zig
// which is exposed as httpz.testing.
const std = @import("std");
const httpz = @import("httpz.zig");

const Conn = @import("worker.zig").Conn;
const BufferPool = @import("buffer.zig").Pool;

pub fn expectEqual(expected: anytype, actual: anytype) !void {
	try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub const allocator = std.testing.allocator;
pub var arena = std.heap.ArenaAllocator.init(allocator);

pub fn reset() void {
	_ = arena.reset(.free_all);
}

pub fn getRandom() std.rand.DefaultPrng {
	var seed: u64 = undefined;
	std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
	return std.rand.DefaultPrng.init(seed);
}

pub const Context = struct {
	// the stream that the server gets
	stream: std.net.Stream,

	// the client (e.g. browser stream)
	client: std.net.Stream,

	closed: bool = false,

	conn: *Conn,

	arena: *std.heap.ArenaAllocator,

	pub fn allocInit(ctx_allocator: std.mem.Allocator, config_: httpz.Config) Context {
		var pair: [2]c_int = undefined;
		const rc = std.c.socketpair(std.os.AF.LOCAL, std.os.SOCK.STREAM, 0, &pair);
		if (rc != 0) {
			@panic("socketpair fail");
		}

		{
			const timeout = std.mem.toBytes(std.os.timeval{
				.tv_sec = 0,
				.tv_usec = 20_000,
			});
			std.os.setsockopt(pair[0], std.os.SOL.SOCKET, std.os.SO.RCVTIMEO, &timeout) catch unreachable;
			std.os.setsockopt(pair[0], std.os.SOL.SOCKET, std.os.SO.SNDTIMEO, &timeout) catch unreachable;
			std.os.setsockopt(pair[1], std.os.SOL.SOCKET, std.os.SO.RCVTIMEO, &timeout) catch unreachable;
			std.os.setsockopt(pair[1], std.os.SOL.SOCKET, std.os.SO.SNDTIMEO, &timeout) catch unreachable;

			// for request.fuzz, which does up to an 8K write. Not sure why this has
			// to be so much more but on linux, even a 10K SNDBUF results in WOULD_BLOCK.
			std.os.setsockopt(pair[1], std.os.SOL.SOCKET, std.os.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 20_000))) catch unreachable;
		}

		const server = std.net.Stream{.handle = pair[0]};
		const client = std.net.Stream{.handle = pair[1]};

		var ctx_arena = ctx_allocator.create(std.heap.ArenaAllocator) catch unreachable;
		ctx_arena.* = std.heap.ArenaAllocator.init(ctx_allocator);
		const aa = ctx_arena.allocator();


		const bp = aa.create(BufferPool) catch unreachable;
		bp.* = BufferPool.init(aa, 2, 256) catch unreachable;

		var config = config_;
		{
			// Various parts of the code using pretty generous defaults. For tests
			// we can use more conservative values.
			const cw = config.workers;
			if (cw.count == null) config.workers.count = 2;
			if (cw.max_conn == null) config.workers.max_conn = 2;
			if (cw.min_conn == null) config.workers.min_conn = 1;
			if (cw.large_buffer_count == null) config.workers.large_buffer_count = 1;
			if (cw.large_buffer_size == null) config.workers.large_buffer_size = 256;
		}

			// a bit over the top..we could use ctx_arena here, but this better mimics
		// the actual code where the conn has a distinct arena (whereas ctx_arena is
		// something specific to this test context)
		const conn_arena = aa.create(std.heap.ArenaAllocator) catch unreachable;
		conn_arena.* = std.heap.ArenaAllocator.init(aa);

		const req_state = httpz.Request.State.init(aa, conn_arena, bp, &config.request) catch unreachable;
		const res_state = httpz.Response.State.init(aa, conn_arena, bp, &config.response) catch unreachable;

		const conn = aa.create(Conn) catch unreachable;
		conn.* = .{
			.state = .active,
			.stream = server,
			.address = std.net.Address.initIp4([_]u8{127, 0, 0, 200}, 0),
			.req_state = req_state,
			.res_state = res_state,
			.websocket = undefined,
			.next = null,
			.prev = null,
			.timeout = 0,
			.request_count = 0,
			.close = false,
			.io_mode = .nonblocking,
			.poll_mode = .read,
			.socket_flags = 0,
			.arena = conn_arena,
		};

		return .{
			.conn = conn,
			.arena = ctx_arena,
			.stream = server,
			.client = client,
		};
	}

	pub fn init(config: httpz.Config) Context {
		return allocInit(allocator, config);
	}

	pub fn deinit(self: *Context) void {
		if (self.closed == false) {
			self.closed = true;
			self.stream.close();
		}
		self.client.close();

		const ctx_allocator = arena.child_allocator;
		self.arena.deinit();
		ctx_allocator.destroy(self.arena);
	}

	// force the server side socket to be closed, which helps our reading-test
	// know that there's no more data.
	pub fn close(self: *Context) void {
		if (self.closed == false) {
			self.closed = true;
			self.stream.close();
		}
	}

	pub fn write(self: Context, data: []const u8) void {
		self.client.writeAll(data) catch unreachable;
	}

	pub fn read(self: Context, a: std.mem.Allocator) !std.ArrayList(u8) {
		var buf: [1024]u8 = undefined;
		var arr = std.ArrayList(u8).init(a);

		while (true) {
			const n = self.client.read(&buf) catch |err| switch (err) {
				error.WouldBlock => return arr,
				else => return err,
			};
			if (n == 0) return arr;
			try arr.appendSlice(buf[0..n]);
		}
		unreachable;
	}

	pub fn expect(self: Context, expected: []const u8) !void {
		var pos: usize = 0;
		var buf = try allocator.alloc(u8, expected.len);
		defer allocator.free(buf);
		while (pos < buf.len) {
			const n = try self.client.read(buf[pos..]);
			if (n == 0) break;
			pos += n;
		}
		try expectString(expected, buf);
	}

	pub fn request(self: Context) httpz.Request {
		return httpz.Request.init(self.conn.arena.allocator(), self.conn);
	}

	pub fn response(self: Context) httpz.Response {
		return httpz.Response.init(self.conn.arena.allocator(), self.conn);
	}
};

pub fn randomString(random: std.rand.Random, a: std.mem.Allocator, max: usize) []u8 {
	var buf = a.alloc(u8, random.uintAtMost(usize, max) + 1) catch unreachable;
	const valid = "abcdefghijklmnopqrstuvwxyz0123456789-_/";
	for (0..buf.len) |i| {
		buf[i] = valid[random.uintAtMost(usize, valid.len-1)];
	}
	return buf;
}
