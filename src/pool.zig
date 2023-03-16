const std = @import("std");
const t = @import("t.zig");
const cm = @import("concurrent_map.zig");

// async: const Lock = std.event.Lock;
const Allocator = std.mem.Allocator;

pub const io_mode = .evented;

pub fn Pool(comptime E: type, comptime S: type) type {
	const initFnPtr = *const fn (Allocator, S) anyerror!E;
	const ConcurrentMap = cm.ConcurrentMap(usize, void);

	return struct {
		// async: lock: Lock,
		items: []E,
		available: usize,
		allocator: Allocator,
		initFn: initFnPtr,
		initState: S,
		dynamic: ConcurrentMap,

		const Self = @This();

		pub fn init(allocator: Allocator, size: usize, initFn: initFnPtr, initState: S) !Self {
			const items = try allocator.alloc(E, size);

			for (0..size) |i| {
				items[i] = try initFn(allocator, initState);
			}

			return Self{
				// async: .lock = RwLock.init(),
				.items = items,
				.initFn = initFn,
				.initState = initState,
				.available = size,
				.allocator = allocator,
				.dynamic = ConcurrentMap.init(allocator),
			};
		}

		pub fn deinit(self: *Self) void {
			const allocator = self.allocator;
			for (self.items) |e| {
				e.deinit(allocator);
				allocator.destroy(e);
			}
			self.dynamic.deinit();
			allocator.free(self.items);
		}

		pub fn acquire(self: *Self) !E {
		   // async:  var held = self.lock.acquire();
			const items = self.items;
			const available = self.available;
			if (available == 0) {
				// dont hold the lock over factory
				// async: held.release();;
				const e = try self.initFn(self.allocator, self.initState);
				try self.dynamic.put(@ptrToInt(e), {});
				return e;
			}
			const index = available - 1;
			const e = items[index];
			self.available = index;
			// async: held.release();
			return e;
		}

		pub fn release(self: *Self, e: E) void {
			e.reset();
			_ = self.dynamic.remove(@ptrToInt(e));

			// Even if this was a dynamically created item, we'll add it back
			// to the pool [if there's space]

			// async: var held = self.lock.acquire();
			var items = self.items;
			const available = self.available;
			if (available == items.len) {
				// async: held.release();
				const allocator = self.allocator;
				e.deinit(allocator);
				allocator.destroy(e);
				return;
			}
			items[available] = e;
			self.available = available + 1;
			// async: held.release();
		}
	};
}

var id: i32 = 0;
const TestEntry = struct {
	id: i32,
	resetted: bool,
	deinited: bool,


	pub fn init(allocator: Allocator, incr: i32) !*TestEntry {
		id += incr;
		var entry = try allocator.create(TestEntry);
		entry.id = id;
		return entry;
	}

	pub fn deinit(self: *TestEntry, _: Allocator) void {
		self.deinited = true;
	}

	pub fn reset(self: *TestEntry) void {
		self.resetted = true;
	}
};

test "pool: acquires & release" {
	var p = try Pool(*TestEntry, i32).init(t.allocator, 2, TestEntry.init, 5);
	defer p.deinit();

	var e1 = try p.acquire();
	try t.expectEqual(@as(i32, 10), e1.id);
	try t.expectEqual(false, e1.resetted);
	try t.expectEqual(false, e1.deinited);

	var e2 = try p.acquire();
	try t.expectEqual(@as(i32, 5), e2.id);
	try t.expectEqual(false, e2.resetted);
	try t.expectEqual(false, e2.deinited);

	var e3 = try p.acquire();
	try t.expectEqual(@as(i32, 15), e3.id);
	try t.expectEqual(false, e3.resetted);
	try t.expectEqual(false, e3.deinited);

	// released first, so back in the pool
	p.release(e3);
	try t.expectEqual(@as(i32, 15), e3.id);
	try t.expectEqual(true, e3.resetted);
	try t.expectEqual(false, e3.deinited);

	p.release(e2);
	try t.expectEqual(@as(i32, 5), e2.id);
	try t.expectEqual(true, e2.resetted);
	try t.expectEqual(false, e2.deinited);

	p.release(e1);
	// TODO: how to test that e1 was properly released?
}
