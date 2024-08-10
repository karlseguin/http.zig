const std = @import("std");

const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

fn MakeKeyValue(K: type, V: type, equalFn: fn (lhs: K, rhs: K) bool) type {
    return struct {
        len: usize,
        keys: []K,
        values: []V,

        pub const Value = V;

        const Self = @This();

        pub fn init(allocator: Allocator, max: usize) !Self {
            return .{
                .len = 0,
                .keys = try allocator.alloc(K, max),
                .values = try allocator.alloc(V, max),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.keys);
            allocator.free(self.values);
        }

        pub fn add(self: *Self, key: K, value: V) void {
            const len = self.len;
            var keys = self.keys;
            if (len == keys.len) {
                return;
            }

            keys[len] = key;
            self.values[len] = value;
            self.len = len + 1;
        }

        pub fn get(self: *const Self, needle: K) ?V {
            const keys = self.keys[0..self.len];
            for (keys, 0..) |key, i| {
                if (equalFn(key, needle)) {
                    // return key;
                    return self.values[i];
                }
            }
            return null;
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
        }
    };
}

fn strEql(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, lhs, rhs);
}

pub const KeyValue = MakeKeyValue([]const u8, []const u8, strEql);

const MultiForm = struct {
    value: []const u8,
    filename: ?[]const u8 = null,
};
pub const MultiFormKeyValue = MakeKeyValue([]const u8, MultiForm, strEql);

const t = @import("t.zig");
test "KeyValue: get" {
    var kv = try KeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);

    var key = "content-type".*;
    kv.add(&key, "application/json");

    try t.expectEqual("application/json", kv.get("content-type").?);

    kv.reset();
    try t.expectEqual(null, kv.get("content-type"));
    kv.add(&key, "application/json2");
    try t.expectEqual("application/json2", kv.get("content-type").?);
}

test "KeyValue: ignores beyond max" {
    var kv = try KeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);
    var n1 = "content-length".*;
    kv.add(&n1, "cl");

    var n2 = "host".*;
    kv.add(&n2, "www");

    var n3 = "authorization".*;
    kv.add(&n3, "hack");

    try t.expectEqual("cl", kv.get("content-length").?);
    try t.expectEqual("www", kv.get("host").?);
    try t.expectEqual(null, kv.get("authorization"));
}

test "MultiFormKeyValue: get" {
    var kv = try MultiFormKeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);

    var key = "username".*;
    kv.add(&key, .{.value = "leto"});

    try t.expectEqual("leto", kv.get("username").?.value);

    kv.reset();
    try t.expectEqual(null, kv.get("username"));
    kv.add(&key, .{.value = "leto2"});
    try t.expectEqual("leto2", kv.get("username").?.value);
}

test "MultiFormKeyValue: ignores beyond max" {
    var kv = try MultiFormKeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);

    var n1 = "username".*;
    kv.add(&n1, .{.value = "leto"});

    var n2 = "password".*;
    kv.add(&n2, .{.value = "ghanima"});

    var n3 = "other".*;
    kv.add(&n3, .{.value = "hack"});

    try t.expectEqual("leto", kv.get("username").?.value);
    try t.expectEqual("ghanima", kv.get("password").?.value);
    try t.expectEqual(null, kv.get("other"));
}
