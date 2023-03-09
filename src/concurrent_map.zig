const std = @import("std");
const t = @import("t.zig");

// async: const RwLock = std.event.RwLock;
const Allocator = std.mem.Allocator;

pub fn ConcurrentMap(comptime K: type, comptime V: type) type {
	return struct {
		// async: lock: RwLock,
		map: std.AutoHashMap(K, V),

		const Self = @This();

		pub fn init(allocator: Allocator) Self {
			return .{
				// async: .lock = RwLock.init(),
				.map = std.AutoHashMap(K, V).init(allocator),
			};
		}

		pub fn deinit(self: *Self) void {
			self.map.deinit();
			// async: self.lock.deinit();
		}

		pub fn put(self: *Self, key: K, value: V) Allocator.Error!void {
			// async: var held = self.lock.acquireWrite();
			// async: defer held.release();
			return self.map.put(key, value);
		}

		pub fn get(self: *Self, key: K) ?V {
			// async: var held = self.lock.acquireRead();
			// async: defer held.release();
			return self.map.get(key);
		}

		pub fn remove(self: *Self, key: K) bool {
			// async: var held = self.lock.acquireWrite();
			// async: defer held.release();
			return self.map.remove(key);
		}
	};
}

test "concurrent_map: get and put" {
	var m = ConcurrentMap(i32, bool).init(t.allocator);
	defer m.deinit();
	try t.expectEqual(@as(?bool, null), m.get(32));
	try t.expectEqual(@as(?bool, null), m.get(99));
	try t.expectEqual(false, m.remove(32));
	try t.expectEqual(false, m.remove(99));

	try m.put(32, true);
	try t.expectEqual(@as(?bool, true), m.get(32));
	try t.expectEqual(@as(?bool, null), m.get(99));

	try m.put(32, false);
	try t.expectEqual(@as(?bool, false), m.get(32));
	try t.expectEqual(@as(?bool, null), m.get(99));

	try t.expectEqual(true, m.remove(32));
	try t.expectEqual(false, m.remove(99));
	try t.expectEqual(@as(?bool, null), m.get(32));
	try t.expectEqual(@as(?bool, null), m.get(99));
}
