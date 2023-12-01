const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Buffer = struct {
	data: []u8,
	type: Type,

	const Type = enum {
		static,
		pooled,
		dynamic,
	};
};

pub const Pool = struct {
	available: usize,
	buffers: []Buffer,
	allocator: Allocator,
	buffer_size: usize,

	pub fn init(allocator: Allocator, count: usize, buffer_size: usize) !Pool {
		const buffers = try allocator.alloc(Buffer, count);

		for (0..count) |i| {
			buffers[i] = .{
				.type = .pooled,
				.data = try allocator.alloc(u8, buffer_size),
			};
		}

		return .{
			.buffers = buffers,
			.available = count,
			.allocator = allocator,
			.buffer_size = buffer_size,
		};
	}

	pub fn deinit(self: *Pool) void {
		const allocator = self.allocator;
		for (self.buffers) |buf| {
			allocator.free(buf.data);
		}
		allocator.free(self.buffers);
	}

	pub fn acquire(self: *Pool, size: usize) !Buffer {
		if (size > self.buffer_size) {
			return .{
				.type = .dynamic,
				.data = try self.allocator.alloc(u8, size),
			};
		}

		const available = self.available;
		if (available == 0) {
			return .{
				.type = .dynamic,
				.data = try self.allocator.alloc(u8, size),
			};
		}

		const index = available - 1;
		const buffer = self.buffers[index];
		self.available = index;
		return buffer;
	}

	pub fn release(self: *Pool, buffer: Buffer) void {
		switch (buffer.type) {
			.static => {},
			.dynamic => self.allocator.free(buffer.data),
			.pooled => {
				const available = self.available;
				self.buffers[available] = buffer;
				self.available = available + 1;
			}
		}
	}
};

const t = @import("t.zig");
test "Buffer: Pool" {
	var pool = try Pool.init(t.allocator, 2, 10);
	defer pool.deinit();

	{
		// bigger than our buffers in pool
		const buffer = try pool.acquire(11);
		defer pool.release(buffer);
		try t.expectEqual(.dynamic, buffer.type);
		try t.expectEqual(11, buffer.data.len);
	}

	{
		// smaller than our buffers in pool
		const buf1 = try pool.acquire(4);
		try t.expectEqual(.pooled, buf1.type);
		try t.expectEqual(10, buf1.data.len);

		const buf2 = try pool.acquire(5);
		try t.expectEqual(.pooled, buf2.type);
		try t.expectEqual(10, buf2.data.len);

		try t.expectEqual(false, &buf1.data[0] == &buf2.data[0]);

		// no more buffers in the pool, creats a dynamic buffer
		const buf3 = try pool.acquire(6);
		try t.expectEqual(.dynamic, buf3.type);
		try t.expectEqual(6, buf3.data.len);

		pool.release(buf1);

		// now has items!
		const buf4 = try pool.acquire(6);
		try t.expectEqual(.pooled, buf4.type);
		try t.expectEqual(10, buf4.data.len);

		pool.release(buf2);
		pool.release(buf3);
		pool.release(buf4);
	}
}
