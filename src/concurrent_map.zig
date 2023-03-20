const std = @import("std");
const t = @import("t.zig");

const RwLock = std.Thread.RwLock;
// async: const RwLock = std.event.RwLock;
const Allocator = std.mem.Allocator;

pub fn ConcurrentMap(comptime K: type, comptime V: type) type {
	return struct {
		lock: RwLock,
		map: std.AutoHashMap(K, V),

		const Self = @This();

		pub fn init(allocator: Allocator) Self {
			return .{
				.lock = RwLock{},
				.map = std.AutoHashMap(K, V).init(allocator),
			};
		}

		pub fn deinit(self: *Self) void {
			self.map.deinit();
		}

		pub fn put(self: *Self, key: K, value: V) Allocator.Error!void {
			var l = self.lock;
			l.lock();
			defer l.unlock();
			return self.map.put(key, value);
		}

		pub fn get(self: *Self, key: K) ?V {
			var l = self.lock;
			l.lockShared();
			defer l.unlockShared();
			return self.map.get(key);
		}

		pub fn remove(self: *Self, key: K) bool {
			var l = self.lock;
			l.lock();
			defer l.unlock();

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
