const std = @import("std");

const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

fn KeyValue(K: type, V: type, equalFn: fn (lhs: K, rhs: K) callconv(.Inline) bool, hashFn: fn (key: K) callconv(.Inline) u8) type {
    return struct {
        len: usize,
        keys: []K,
        values: []V,
        hashes: []u8,

        pub const Value = V;

        const Self = @This();

        pub fn init(allocator: Allocator, max: usize) !Self {
            return .{
                .len = 0,
                .keys = try allocator.alloc(K, max),
                .values = try allocator.alloc(V, max),
                .hashes = try allocator.alloc(u8, max),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.keys);
            allocator.free(self.values);
            allocator.free(self.hashes);
        }

        pub fn add(self: *Self, key: K, value: V) void {
            const len = self.len;
            var keys = self.keys;
            if (len == keys.len) {
                return;
            }

            keys[len] = key;
            self.values[len] = value;
            self.hashes[len] = hashFn(key);
            self.len = len + 1;
        }

        pub fn get(self: *const Self, key: K) ?V {
            const hash = hashFn(key);
            for (self.hashes[0..self.len], 0..) |h, i| {
                if (h == hash and equalFn(self.keys[i], key)) {
                    return self.values[i];
                }
            }
            return null;
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
        }

        pub fn iterator(self: *const Self) Iterator {
            const len = self.len;
            return .{
                .pos = 0,
                .keys = self.keys[0..len],
                .values = self.values[0..len],
            };
        }

        pub const Iterator = struct {
            pos: usize,
            keys: [][]const u8,
            values: []V,

            const KV = struct {
                key: []const u8,
                value: V,
            };

            pub fn next(self: *Iterator) ?KV {
                const pos = self.pos;
                if (pos == self.keys.len) {
                    return null;
                }

                self.pos = pos + 1;
                return .{
                    .key = self.keys[pos],
                    .value = self.values[pos],
                };
            }
        };
    };
}

inline fn strHash(key: []const u8) u8 {
    if (key.len == 0) {
        return 0;
    }
    return @as(u8, @truncate(key.len)) | (key[0]) ^ (key[key.len - 1]);
}

inline fn strEql(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, lhs, rhs);
}

pub const StringKeyValue = KeyValue([]const u8, []const u8, strEql, strHash);

const MultiForm = struct {
    value: []const u8,
    filename: ?[]const u8 = null,
};
pub const MultiFormKeyValue = KeyValue([]const u8, MultiForm, strEql, strHash);

const t = @import("t.zig");
test "KeyValue: get" {
    var kv = try StringKeyValue.init(t.allocator, 2);
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
    var kv = try StringKeyValue.init(t.allocator, 2);
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

    {
        var it = kv.iterator();
        {
            const field = it.next().?;
            try t.expectString("content-length", field.key);
            try t.expectString("cl", field.value);
        }

        {
            const field = it.next().?;
            try t.expectString("host", field.key);
            try t.expectString("www", field.value);
        }
        try t.expectEqual(null, it.next());
    }
}

test "MultiFormKeyValue: get" {
    var kv = try MultiFormKeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);

    var key = "username".*;
    kv.add(&key, .{ .value = "leto" });

    try t.expectEqual("leto", kv.get("username").?.value);

    kv.reset();
    try t.expectEqual(null, kv.get("username"));
    kv.add(&key, .{ .value = "leto2" });
    try t.expectEqual("leto2", kv.get("username").?.value);
}

test "MultiFormKeyValue: ignores beyond max" {
    var kv = try MultiFormKeyValue.init(t.allocator, 2);
    defer kv.deinit(t.allocator);

    var n1 = "username".*;
    kv.add(&n1, .{ .value = "leto" });

    var n2 = "password".*;
    kv.add(&n2, .{ .value = "ghanima" });

    var n3 = "other".*;
    kv.add(&n3, .{ .value = "hack" });

    try t.expectEqual("leto", kv.get("username").?.value);
    try t.expectEqual("ghanima", kv.get("password").?.value);
    try t.expectEqual(null, kv.get("other"));

    {
        var it = kv.iterator();
        {
            const field = it.next().?;
            try t.expectString("username", field.key);
            try t.expectString("leto", field.value.value);
        }

        {
            const field = it.next().?;
            try t.expectString("password", field.key);
            try t.expectString("ghanima", field.value.value);
        }
        try t.expectEqual(null, it.next());
    }
}
