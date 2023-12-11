const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Buffer = struct {
	data: []u8,
	type: Type,

	const Type = enum {
		arena,
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

	pub fn grow(self: *Pool, arena: Allocator, buffer: *Buffer, current_size: usize, new_size: usize) !Buffer {
		if (buffer.type == .dynamic and arena.resize(buffer.data, new_size)) {
			buffer.data = buffer.data.ptr[0..new_size];
			return buffer.*;
		}
		const new_buffer = try self.arenaAlloc(arena, new_size);
		@memcpy(new_buffer.data[0..current_size], buffer.data[0..current_size]);
		self.free(buffer.*);
		return new_buffer;
	}

	pub fn static(self: Pool, size: usize) !Buffer {
		return .{
			.type = .static,
			.data = try self.allocator.alloc(u8, size),
		};
	}

	pub fn alloc(self: *Pool, size: usize) !Buffer {
		return self.allocType(self.allocator, .dynamic, size);
	}

	pub fn arenaAlloc(self: *Pool, arena: Allocator, size: usize) !Buffer {
		return self.allocType(arena, .arena, size);
	}

	fn allocType(self: *Pool, allocator: Allocator, buffer_type: Buffer.Type, size: usize) !Buffer {
		const available = self.available;
		if (size > self.buffer_size or available == 0) {
			return .{
				.type = buffer_type,
				.data = try allocator.alloc(u8, size),
			};
		}

		const index = available - 1;
		const buffer = self.buffers[index];
		self.available = index;
		return buffer;
	}

	pub fn free(self: *Pool, buffer: Buffer) void {
		switch (buffer.type) {
			.arena => {},
			.pooled => self.release(buffer),
			.static => self.allocator.free(buffer.data),
			.dynamic => self.allocator.free(buffer.data),
		}
	}

	pub fn release(self: *Pool, buffer: Buffer) void {
		switch (buffer.type) {
			.static, .arena => {},
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
test "BufferPool" {
	var pool = try Pool.init(t.allocator, 2, 10);
	defer pool.deinit();

	{
		// bigger than our buffers in pool
		const buffer = try pool.alloc(11);
		defer pool.release(buffer);
		try t.expectEqual(.dynamic, buffer.type);
		try t.expectEqual(11, buffer.data.len);
	}

	{
		// smaller than our buffers in pool
		const buf1 = try pool.alloc(4);
		try t.expectEqual(.pooled, buf1.type);
		try t.expectEqual(10, buf1.data.len);

		const buf2 = try pool.alloc(5);
		try t.expectEqual(.pooled, buf2.type);
		try t.expectEqual(10, buf2.data.len);

		try t.expectEqual(false, &buf1.data[0] == &buf2.data[0]);

		// no more buffers in the pool, creats a dynamic buffer
		const buf3 = try pool.alloc(6);
		try t.expectEqual(.dynamic, buf3.type);
		try t.expectEqual(6, buf3.data.len);

		pool.release(buf1);

		// now has items!
		const buf4 = try pool.alloc(6);
		try t.expectEqual(.pooled, buf4.type);
		try t.expectEqual(10, buf4.data.len);

		pool.release(buf2);
		pool.release(buf3);
		pool.release(buf4);
	}
}

test "BufferPool: grow" {
	defer t.reset();

	var pool = try Pool.init(t.allocator, 1, 10);
	defer pool.deinit();

	{
		// grow a dynamic buffer
		var buf1 = try pool.alloc(15);
		@memcpy(buf1.data[0..5], "hello");
		const buf2 = try pool.grow(t.arena.allocator(), &buf1, 5, 20);
		defer pool.free(buf2);
		try t.expectEqual(20, buf2.data.len);
		try t.expectString("hello", buf2.data[0..5]);
	}

	{
		// grow a static buffer
		var buf1 = try pool.static(15);
		@memcpy(buf1.data[0..6], "hello2");
		const buf2 = try pool.grow(t.arena.allocator(), &buf1, 6, 21);
		defer pool.free(buf2);
		try t.expectEqual(21, buf2.data.len);
		try t.expectString("hello2", buf2.data[0..6]);
	}

	{
		// grow a pooled buffer
		var buf1 = try pool.alloc(8);
		@memcpy(buf1.data[0..7], "hello2a");
		const buf2 = try pool.grow(t.arena.allocator(), &buf1, 7, 14);
		defer pool.free(buf2);
		try t.expectEqual(14, buf2.data.len);
		try t.expectString("hello2a", buf2.data[0..7]);
		try t.expectEqual(1, pool.available);
	}
}
