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

// The current std implementation of std.mem.eql without the pointer comparison 
// and faster implementation for `string.len <= 16`
fn strEql(a: []const u8, b: []const u8) bool {
    // TODO: monitor https://github.com/ziglang/zig/issues/8689
    if (a.len != b.len) return false;
    if (a.len == 0) return true;

    switch (a.len) {
        0  => return true,
        1  => return 0 == (a[0] ^ b[0]),
        2  => return 0 == (@as(u16, @bitCast(a[0..2].*)) ^ @as(u16, @bitCast(b[0..2].*))),
        3  => return 0 == (@as(u16, @bitCast(a[0..2].*)) ^ @as(u16, @bitCast(b[0..2].*))) and 0 == (a[2] ^ b[2]),
        4  => return 0 == (@as(u32, @bitCast(a[0..4].*)) ^ @as(u32, @bitCast(b[0..4].*))),
        5  => return 0 == (@as(u32, @bitCast(a[0..4].*)) ^ @as(u32, @bitCast(b[0..4].*))) and 0 == (a[4] ^ b[4]),
        6  => return 0 == (@as(u32, @bitCast(a[0..4].*)) ^ @as(u32, @bitCast(b[0..4].*))) and 0 == (@as(u16, @bitCast(a[4..6].*)) ^ @as(u16, @bitCast(b[4..6].*))),
        7  => return 0 == (@as(u32, @bitCast(a[0..4].*)) ^ @as(u32, @bitCast(b[0..4].*))) and 0 == (@as(u16, @bitCast(a[4..6].*)) ^ @as(u16, @bitCast(b[4..6].*))) and 0 == (a[6] ^ b[6]),
        8  => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))),
        9  => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))) and 0 == (a[8] ^ b[8]),
        10 => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))) and 0 == (@as(u16, @bitCast(a[8..10].*)) ^ @as(u16, @bitCast(b[8..10].*))),
        11 => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))) and 0 == (@as(u16, @bitCast(a[8..10].*)) ^ @as(u16, @bitCast(b[8..10].*))) and 0 == (a[10] ^ b[10]),
        12 => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))) and 0 == (@as(u32, @bitCast(a[8..12].*)) ^ @as(u32, @bitCast(b[8..12].*))),
        13 => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))) and 0 == (@as(u32, @bitCast(a[8..12].*)) ^ @as(u32, @bitCast(b[8..12].*))) and 0 == (a[12] ^ b[12]),
        14 => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))) and 0 == (@as(u32, @bitCast(a[8..12].*)) ^ @as(u32, @bitCast(b[8..12].*))) and 0 == (@as(u16, @bitCast(a[12..14].*)) ^ @as(u16, @bitCast(b[12..14].*))),
        15 => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))) and 0 == (@as(u32, @bitCast(a[8..12].*)) ^ @as(u32, @bitCast(b[8..12].*))) and 0 == (@as(u16, @bitCast(a[12..14].*)) ^ @as(u16, @bitCast(b[12..14].*))) and 0 == (a[14] ^ b[14]),
        16 => return 0 == (@as(u64, @bitCast(a[0..8].*)) ^ @as(u64, @bitCast(b[0..8].*))) and 0 == (@as(u64, @bitCast(a[8..16].*)) ^ @as(u64, @bitCast(b[8..16].*))),
        else => {},
    }

    // Figure out the fastest way to scan through the input in chunks.
    // Uses vectors when supported and falls back to usize/words when not.
    const Scan = if (std.simd.suggestVectorLength(u8)) |vec_size|
        struct {
            pub const size = vec_size;
            pub const Chunk = @Vector(size, u8);
            pub inline fn isNotEqual(chunk_a: Chunk, chunk_b: Chunk) bool {
                return @reduce(.Or, chunk_a != chunk_b);
            }
        }
    else
        struct {
            pub const size = @sizeOf(usize);
            pub const Chunk = usize;
            pub inline fn isNotEqual(chunk_a: Chunk, chunk_b: Chunk) bool {
                return chunk_a != chunk_b;
            }
        };

    inline for (1..6) |s| {
        const n = 16 << s;
        if (n <= Scan.size and a.len <= n) {
            const V = @Vector(n / 2, u8);
            var x = @as(V, a[0 .. n / 2].*) ^ @as(V, b[0 .. n / 2].*);
            x |= @as(V, a[a.len - n / 2 ..][0 .. n / 2].*) ^ @as(V, b[a.len - n / 2 ..][0 .. n / 2].*);
            const zero: V = @splat(0);
            return !@reduce(.Or, x != zero);
        }
    }
    // Compare inputs in chunks at a time (excluding the last chunk).
    for (0..(a.len - 1) / Scan.size) |i| {
        const a_chunk: Scan.Chunk = @bitCast(a[i * Scan.size ..][0..Scan.size].*);
        const b_chunk: Scan.Chunk = @bitCast(b[i * Scan.size ..][0..Scan.size].*);
        if (Scan.isNotEqual(a_chunk, b_chunk)) return false;
    }

    // Compare the last chunk using an overlapping read (similar to the previous size strategies).
    const last_a_chunk: Scan.Chunk = @bitCast(a[a.len - Scan.size ..][0..Scan.size].*);
    const last_b_chunk: Scan.Chunk = @bitCast(b[a.len - Scan.size ..][0..Scan.size].*);
    return !Scan.isNotEqual(last_a_chunk, last_b_chunk);
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

test "strEql" {
    comptime var string: []const u8 = &.{};

    inline for (0..256) |i| {
        string = string ++ [1]u8{@truncate(i)};

        const a: []u8 = try t.allocator.alloc(u8, string.len);
        defer t.allocator.free(a);
        @memcpy(a, string);

        const b: []u8 = try t.allocator.alloc(u8, string.len);
        defer t.allocator.free(b);
        @memcpy(b, string);

        try t.expectEqual(strEql(a, b), true);
        
        a[a.len - 1] = if (a[a.len - 1] == 0) 1 else 0;
        try t.expectEqual(strEql(a, b), false);
    }
}
