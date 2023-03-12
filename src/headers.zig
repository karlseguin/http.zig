const std = @import("std");
const t = @import("t.zig");

const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

pub const Headers = struct {
	len: usize,
	names: [][]u8,
	values: [][]const u8,
	allocator: Allocator,

	const Self = @This();

	pub fn init(allocator: Allocator, max: usize) !Self {
		const names = try allocator.alloc([]u8, max);
		const values = try allocator.alloc([]const u8, max);
		return Self{
			.len = 0,
			.names = names,
			.values = values,
			.allocator = allocator,
		};
	}

	pub fn add(self: *Self, name: []u8, value: []const u8) void {
		const len = self.len;
		var names = self.names;
		if (len == names.len) {
			return;
		}

		for (name, 0..) |c, i| {
			name[i] = ascii.toLower(c);
		}

		names[len] = name;
		self.values[len] = value;
		self.len = len + 1;
	}

	pub fn get(self: *Self, needle: []const u8) ?[]const u8 {
		const names = self.names[0..self.len];
		for (names, 0..) |name, i| {
			if (mem.eql(u8, name, needle)) {
				return self.values[i];
			}
		}

		return null;
	}

	pub fn reset(self: *Self) void {
		self.len = 0;
	}

	pub fn deinit(self: *Self) void {
		self.allocator.free(self.names);
		self.allocator.free(self.values);
	}
};

test "gets header value" {
	var allocator = t.allocator;
	const variations = [_][]const u8{ "content-type", "Content-Type", "cONTENT-tYPE", "CONTENT-TYPE" };
	for (variations) |header| {
		var h = try Headers.init(allocator, 1);
		var name = try mutableString(header);
		h.add(name, "application/json");

		try t.expectEqual(@as(?[]const u8, "application/json"), h.get("content-type"));

		h.reset();
		try t.expectEqual(@as(?[]const u8, null), h.get("content-type"));
		h.add(name, "application/json2");
		try t.expectEqual(@as(?[]const u8, "application/json2"), h.get("content-type"));

		h.deinit();
		allocator.free(name);
	}
}

test "ignores headers beyond max" {
	var h = try Headers.init(t.allocator, 2);
	var n1 = try mutableString("content-length");
	h.add(n1, "cl");

	var n2 = try mutableString("host");
	h.add(n2, "www");

	var n3 = try mutableString("authorization");
	h.add(n3, "hack");

	try t.expectEqual(@as(?[]const u8, "cl"), h.get("content-length"));
	try t.expectEqual(@as(?[]const u8, "www"), h.get("host"));
	try t.expectEqual(@as(?[]const u8, null), h.get("authorization"));

	h.deinit();
	t.allocator.free(n1);
	t.allocator.free(n2);
	t.allocator.free(n3);
}

fn mutableString(str: []const u8) ![]u8 {
	var b = try t.allocator.alloc(u8, str.len);
	std.mem.copy(u8, b, str);
	return b;
}
