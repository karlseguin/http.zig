const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Config = struct {
	min: usize = 20,
	max: usize = 500,
	timeout: u64 = 5000, // ms
};

pub fn Pool(comptime E: type, comptime S: type) type {
	const initFnPtr = *const fn (S) anyerror!E;

	return struct {
		items: []E,
		overflow: usize,
		max_overflow: usize,
		overflow_wait: u64,
		available: usize,
		allocator: Allocator,
		initFn: initFnPtr,
		initState: S,
		mutex: std.Thread.Mutex,
		cond: std.Thread.Condition,

		const Self = @This();

		pub fn init(allocator: Allocator, config: Config, initFn: initFnPtr, initState: S) !Self {
			const size = config.min;
			const items = try allocator.alloc(E, size);

			for (0..size) |i| {
				items[i] = try initFn(initState);
			}

			return Self{
				.items = items,
				.initFn = initFn,
				.initState = initState,
				.available = size,
				.allocator = allocator,
				.cond = .{},
				.mutex = .{},
				.overflow = 0,
				.max_overflow = config.max - size,
				.overflow_wait = config.timeout * 1_000_000,
			};
		}

		pub fn deinit(self: *Self) void {
			const allocator = self.allocator;
			for (self.items) |e| {
				e.deinit(allocator);
			}
			allocator.free(self.items);
		}

		pub fn acquire(self: *Self) !E {
			const items = self.items;
			self.mutex.lock();
			while (true) {
				const available = self.available;
				if (available == 0) {
					const overflow = self.overflow;
					if (overflow < self.max_overflow) {
						// we have less than our maximum allowed, create a new one
						self.overflow = overflow + 1;
						self.mutex.unlock();
						return try self.initFn(self.initState);
					}

					// We've reached our limit. We'll wait overflow_wait time for a connection
					// to free up
					const overflow_wait = self.overflow_wait;
					if (overflow_wait == 0) {
						return error.ConnectionPoolExhausted;
					}
					self.cond.timedWait(&self.mutex, overflow_wait) catch {
						self.mutex.unlock();
						return error.ConnectionPoolExhausted;
					};
					continue;
				}
				defer self.mutex.unlock();
				const new_available = available - 1;
				self.available = new_available;
				return items[new_available];
			}
		}

		pub fn release(self: *Self, e: E) void {
			const items = self.items;

			self.mutex.lock();
			const available = self.available;

			if (available == items.len) {
				self.overflow -= 1;
				self.mutex.unlock();
				const allocator = self.allocator;
				e.deinit(allocator);
				return;
			}

			defer self.mutex.unlock();
			self.cond.signal();
			items[available] = e;
			self.available = available + 1;
		}
	};
}

const t = @import("t.zig");
test "pool: acquires & release" {
	id = 0;
	var p = try Pool(*TestEntry, i32).init(t.allocator, .{.min = 2}, TestEntry.init, 5);
	defer p.deinit();

	const e1 = try p.acquire();
	try t.expectEqual(@as(i32, 10), e1.id);
	try t.expectEqual(false, e1.deinited);

	const e2 = try p.acquire();
	try t.expectEqual(@as(i32, 5), e2.id);
	try t.expectEqual(false, e2.deinited);

	const e3 = try p.acquire();
	try t.expectEqual(@as(i32, 15), e3.id);
	try t.expectEqual(false, e3.deinited);

	// released first, so back in the pool
	p.release(e3);
	try t.expectEqual(@as(i32, 15), e3.id);
	try t.expectEqual(false, e3.deinited);

	p.release(e2);
	try t.expectEqual(@as(i32, 5), e2.id);
	try t.expectEqual(false, e2.deinited);

	p.release(e1);
	// TODO: how to test that e1 was properly released?
}

test "pool: no limit" {
	const config = Config{.min = 2, .max  = 10000, .timeout = 0};
	var p = try Pool(*TestEntry, i32).init(t.allocator, config, TestEntry.init, 6);
	defer p.deinit();

	var entries: [5000]*TestEntry = undefined;
	for (0..entries.len) |i| {
		entries[i] = try p.acquire();
	}

	for (entries) |entry| {
		p.release(entry);
	}
}

test "pool: timeout" {
	const config = Config{.min = 2, .max  = 4, .timeout = 5};
	var p = try Pool(*TestEntry, i32).init(t.allocator, config, TestEntry.init, 6);
	defer p.deinit();

	const e1 = try p.acquire();
	defer p.release(e1);

	const e2 = try p.acquire();
	defer p.release(e2);

	const e3 = try p.acquire();
	defer p.release(e3);

	const e4 = try p.acquire();
	defer p.release(e4);

	try t.expectError(error.ConnectionPoolExhausted, p.acquire());
}

test "pool: threadsafety" {
	var p = try Pool(*TestEntry, i32).init(t.allocator, .{.min = 4, .max = 5}, TestEntry.init, 1);
	defer p.deinit();

	const t1 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t2 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t3 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t4 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t5 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t6 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t7 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t8 = try std.Thread.spawn(.{}, testPool, .{&p});

	t1.join(); t2.join(); t3.join(); t4.join();
	t5.join(); t6.join(); t7.join(); t8.join();
}

fn testPool(p: *Pool(*TestEntry, i32)) void {
	var r = t.getRandom();
	const random = r.random();

	for (0..5000) |_| {
		var e = p.acquire() catch unreachable;
		std.debug.assert(e.acquired == false);
		e.acquired = true;
		std.time.sleep(random.uintAtMost(u32, 100000));
		e.acquired = false;
		p.release(e);
	}
}

var id: i32 = 0;
const TestEntry = struct {
	id: i32,
	acquired: bool,
	deinited: bool,

	pub fn init(incr: i32) !*TestEntry {
		id += incr;
		var entry = try t.allocator.create(TestEntry);
		entry.id = id;
		entry.acquired = false;
		return entry;
	}

	pub fn deinit(self: *TestEntry, allocator: Allocator) void {
		self.deinited = true;
		allocator.destroy(self);
	}
};
