const std = @import("std");

const mem = std.mem;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

fn KeyValue(V: type, hashFn: fn (key: []const u8) callconv(.@"inline") u8) type {
    return struct {
        len: usize,
        keys: [][]const u8,
        values: []V,
        hashes: []u8,

        const Self = @This();
        pub const Value = V;

        const alignment = @max(@alignOf([]const u8), @alignOf(V));
        const size = @sizeOf([]const u8) + @sizeOf(V) + @sizeOf(u8);
        const kFirst = @alignOf([]const u8) >= @alignOf(V);

        pub fn init(allocator: Allocator, max: usize) Allocator.Error!Self {
            // we want type with bigger alignment to be first.
            // Since alignment is always a power of 2, the second type is guaranteed to have correct alignment.

            const allocation = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(alignment), max * size);
            return .{
                .len = 0,
                .keys = @as([*][]const u8, @ptrCast(@alignCast(if (kFirst) allocation.ptr else allocation[max * @sizeOf(V) ..].ptr)))[0..max],
                .values = @as([*]V, @ptrCast(@alignCast(if (kFirst) allocation[max * @sizeOf([]const u8) ..].ptr else allocation.ptr)))[0..max],
                .hashes = allocation[max * @sizeOf([]const u8) + max * @sizeOf(V) ..],
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            const allocation = @as([*]align(alignment) u8, @ptrCast(@alignCast(if (kFirst) self.keys.ptr else self.values.ptr)));
            allocator.free(allocation[0 .. self.keys.len * size]);
        }

        pub fn add(self: *Self, key: []const u8, value: V) void {
            const len = self.len;
            const max = self.keys.len;
            var keys = self.keys;
            if (len == max) {
                return;
            }

            keys[len] = key;
            self.values[len] = value;
            self.hashes[len] = hashFn(key);
            self.len = len + 1;
        }

        pub fn get(self: *const Self, key: []const u8) ?V {
            const hash = hashFn(key);
            for (self.hashes[0..self.len], 0..) |h, i| {
                if (h == hash and std.mem.eql(u8, self.keys[i], key)) {
                    return self.values[i];
                }
            }
            return null;
        }

        pub fn getAll(self: *const Self, key: []const u8) ValueIterator {
            const len = self.len;
            return .{
                .pos = 0,
                .key = key,
                .hash = hashFn(key),
                .keys = self.keys[0..len],
                .values = self.values[0..len],
                .hashes = self.hashes[0..len],
            };
        }

        pub fn has(self: *const Self, key: []const u8) bool {
            return self.get(key) != null;
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

        pub const ValueIterator = struct {
            pos: usize,
            hash: u8,
            key: []const u8,
            keys: [][]const u8,
            values: []V,
            hashes: []u8,

            pub fn next(self: *ValueIterator) ?V {
                const key = self.key;
                const hash = self.hash;
                const keys = self.keys;
                var pos = self.pos;
                while (pos < keys.len) {
                    const i = pos;
                    pos += 1;
                    if (self.hashes[i] == hash and std.mem.eql(u8, keys[i], key)) {
                        self.pos = pos;
                        return self.values[i];
                    }
                }
                self.pos = pos;
                return null;
            }
        };
    };
}

inline fn strHash(key: []const u8) u8 {
    if (key.len == 0) {
        return 0;
    }

    var h: u8 = 5;
    for (key) |c| {
        h = h *% 31 +% c;
    }
    return h;
}

pub const StringKeyValue = KeyValue([]const u8, strHash);

const MultiForm = struct {
    value: []const u8,
    filename: ?[]const u8 = null,
};
pub const MultiFormKeyValue = KeyValue(MultiForm, strHash);

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

test "KeyValue: getAll" {
    var kv = try StringKeyValue.init(t.allocator, 5);
    defer kv.deinit(t.allocator);

    {
        var it = kv.getAll("tag");
        try t.expectEqual(null, it.next());
    }

    var k1 = "tag".*;
    var k2 = "other".*;
    kv.add(&k1, "a");
    kv.add(&k2, "x");
    kv.add(&k1, "b");
    kv.add(&k1, "c");

    try t.expectEqual("a", kv.get("tag").?);

    {
        var it = kv.getAll("tag");
        try t.expectString("a", it.next().?);
        try t.expectString("b", it.next().?);
        try t.expectString("c", it.next().?);
        try t.expectEqual(null, it.next());
        try t.expectEqual(null, it.next());
    }

    {
        var it = kv.getAll("other");
        try t.expectString("x", it.next().?);
        try t.expectEqual(null, it.next());
    }

    {
        var it = kv.getAll("nope");
        try t.expectEqual(null, it.next());
    }
}

test "MultiFormKeyValue: getAll" {
    var kv = try MultiFormKeyValue.init(t.allocator, 3);
    defer kv.deinit(t.allocator);

    var k1 = "files".*;
    var k2 = "name".*;
    kv.add(&k1, .{ .value = "c1", .filename = "f1.txt" });
    kv.add(&k2, .{ .value = "leto" });
    kv.add(&k1, .{ .value = "c2", .filename = "f2.txt" });

    var it = kv.getAll("files");
    {
        const f = it.next().?;
        try t.expectString("c1", f.value);
        try t.expectString("f1.txt", f.filename.?);
    }
    {
        const f = it.next().?;
        try t.expectString("c2", f.value);
        try t.expectString("f2.txt", f.filename.?);
    }
    try t.expectEqual(null, it.next());
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
