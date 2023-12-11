const std = @import("std");

const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

pub const KeyValue = struct {
	len: usize,
	keys: [][]const u8,
	values: [][]const u8,

	pub fn init(allocator: Allocator, max: usize) !KeyValue {
		const keys = try allocator.alloc([]const u8, max);
		const values = try allocator.alloc([]const u8, max);
		return .{
			.len = 0,
			.keys = keys,
			.values = values,
		};
	}

	pub fn deinit(self: *KeyValue, allocator: Allocator) void {
		allocator.free(self.keys);
		allocator.free(self.values);
	}

	pub fn add(self: *KeyValue, key: []const u8, value: []const u8) void {
		const len = self.len;
		var keys = self.keys;
		if (len == keys.len) {
			return;
		}

		keys[len] = key;
		self.values[len] = value;
		self.len = len + 1;
	}

	pub fn get(self: KeyValue, needle: []const u8) ?[]const u8 {
		const keys = self.keys[0..self.len];
		for (keys, 0..) |key, i| {
			if (mem.eql(u8, key, needle)) {
				return self.values[i];
			}
		}

		return null;
	}

	pub fn reset(self: *KeyValue) void {
		self.len = 0;
	}
};

const t = @import("t.zig");
test "key_value: get" {
	const allocator = t.allocator;
	var kv = try KeyValue.init(allocator, 2);
	var key = "content-type".*;
	kv.add(&key, "application/json");

	try t.expectEqual("application/json", kv.get("content-type").?);

	kv.reset();
	try t.expectEqual(null, kv.get("content-type"));
	kv.add(&key, "application/json2");
	try t.expectEqual("application/json2", kv.get("content-type").?);

	kv.deinit(t.allocator);
	// allocator.free(key);
}

test "key_value: ignores beyond max" {
	var kv = try KeyValue.init(t.allocator, 2);
	var n1 = "content-length".*;
	kv.add(&n1, "cl");

	var n2 = "host".*;
	kv.add(&n2, "www");

	var n3 = "authorization".*;
	kv.add(&n3, "hack");

	try t.expectEqual("cl", kv.get("content-length").?);
	try t.expectEqual("www", kv.get("host").?);
	try t.expectEqual(null, kv.get("authorization"));

	kv.deinit(t.allocator);
}
