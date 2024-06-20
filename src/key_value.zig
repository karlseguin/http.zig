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
        loop: for (keys, 0..) |key, i| {
            // This is largely a reminder to myself that std.mem.eql isn't
            // particularly fast. Here we at least avoid the 1 extra ptr
            // equality check that std.mem.eql does, but we could do better
            // TODO: monitor https://github.com/ziglang/zig/issues/8689
            if (needle.len != key.len) {
                continue;
            }
            for (needle, key) |n, k| {
                if (n != k) {
                    continue :loop;
                }
            }
            return self.values[i];
        }

        return null;
    }

    pub fn reset(self: *KeyValue) void {
        self.len = 0;
    }
};

pub const MultiFormKeyValue = struct {
    len: usize,
    keys: [][]const u8,
    values: []Value,

   pub const Value = struct {
        value: []const u8,
        filename: ?[]const u8 = null,
    };

    pub fn init(allocator: Allocator, max: usize) !MultiFormKeyValue {
        const keys = try allocator.alloc([]const u8, max);
        const values = try allocator.alloc(Value, max);
        return .{
            .len = 0,
            .keys = keys,
            .values = values,
        };
    }

    pub fn deinit(self: *MultiFormKeyValue, allocator: Allocator) void {
        allocator.free(self.keys);
        allocator.free(self.values);
    }

    pub fn add(self: *MultiFormKeyValue, key: []const u8, value: Value) void {
        const len = self.len;
        var keys = self.keys;
        if (len == keys.len) {
            return;
        }

        keys[len] = key;
        self.values[len] = value;
        self.len = len + 1;
    }

    pub fn get(self: MultiFormKeyValue, needle: []const u8) ?Value {
        const keys = self.keys[0..self.len];
        for (keys, 0..) |key, i| {
            if (mem.eql(u8, key, needle)) {
                return self.values[i];
            }
        }

        return null;
    }

    pub fn reset(self: *MultiFormKeyValue) void {
        self.len = 0;
    }
};

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
