const std = @import("std");
const metrics = @import("metrics.zig");

const Allocator = std.mem.Allocator;

pub const Url = struct {
    raw: []const u8 = "",
    path: []const u8 = "",
    query: []const u8 = "",

    pub fn parse(raw: []const u8) Url {
        var path = raw;
        var query: []const u8 = "";

        if (std.mem.indexOfScalar(u8, raw, '?')) |index| {
            path = raw[0..index];
            query = raw[index + 1 ..];
        }

        return .{
            .raw = raw,
            .path = path,
            .query = query,
        };
    }

    // the special "*" url, which is valid in HTTP OPTIONS request.
    pub fn star() Url {
        return .{
            .raw = "*",
            .path = "*",
            .query = "",
        };
    }

    pub const UnescapeResult = struct {
        // Set to the value, whether or not it required unescaped.
        value: []const u8,

        // true if the value WAS unescaped AND placed in buffer
        buffered: bool,
    };
    // std.Url.unescapeString has 2 problems
    //   First, it doesn't convert '+' -> ' '
    //   Second, it _always_ allocates a new string even if nothing needs to
    //   be unescaped
    // When we _have_ to unescape a key or value, we'll try to store the new
    // value in our static buffer (if we have space), else we'll fallback to
    // allocating memory in the arena.
    pub fn unescape(allocator: Allocator, buffer: []u8, input: []const u8) !UnescapeResult {
        var has_plus = false;
        var unescaped_len = input.len;

        var in_i: usize = 0;
        while (in_i < input.len) {
            const b = input[in_i];
            if (b == '%') {
                if (in_i + 2 >= input.len or !HEX_CHAR[input[in_i + 1]] or !HEX_CHAR[input[in_i + 2]]) {
                    return error.InvalidEscapeSequence;
                }
                in_i += 3;
                unescaped_len -= 2;
            } else if (b == '+') {
                has_plus = true;
                in_i += 1;
            } else {
                in_i += 1;
            }
        }

        // no encoding, and no plus. nothing to unescape
        if (unescaped_len == input.len and !has_plus) {
            return .{ .value = input, .buffered = false };
        }

        var out = buffer;
        var buffered = true;
        if (buffer.len < unescaped_len) {
            out = try allocator.alloc(u8, unescaped_len);
            metrics.allocUnescape(unescaped_len);
            buffered = false;
        }

        in_i = 0;
        for (0..unescaped_len) |i| {
            const b = input[in_i];
            if (b == '%') {
                const enc = input[in_i + 1 .. in_i + 3];
                out[i] = switch (@as(u16, @bitCast(enc[0..2].*))) {
                    asUint("20") => ' ',
                    asUint("21") => '!',
                    asUint("22") => '"',
                    asUint("23") => '#',
                    asUint("24") => '$',
                    asUint("25") => '%',
                    asUint("26") => '&',
                    asUint("27") => '\'',
                    asUint("28") => '(',
                    asUint("29") => ')',
                    asUint("2A") => '*',
                    asUint("2B") => '+',
                    asUint("2C") => ',',
                    asUint("2F") => '/',
                    asUint("3A") => ':',
                    asUint("3B") => ';',
                    asUint("3D") => '=',
                    asUint("3F") => '?',
                    asUint("40") => '@',
                    asUint("5B") => '[',
                    asUint("5D") => ']',
                    else => HEX_DECODE[enc[0]] << 4 | HEX_DECODE[enc[1]],
                };
                in_i += 3;
            } else if (b == '+') {
                out[i] = ' ';
                in_i += 1;
            } else {
                out[i] = b;
                in_i += 1;
            }
        }

        return .{ .value = out[0..unescaped_len], .buffered = buffered };
    }

    pub fn isValid(url: []const u8) bool {
        var rest = url;
        if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
            while (rest.len >= vector_len) {
                const block: @Vector(vector_len, u8) = rest[0..vector_len].*;
                if (@reduce(.Min, block) < 32 or @reduce(.Max, block) > 126) {
                    return false;
                }
                rest = rest[vector_len..];
            }
        }

        for (rest) |c| {
            if (c < 32 or c > 126) {
                return false;
            }
        }

        return true;
    }
};

/// converts ascii to unsigned int of appropriate size
pub fn asUint(comptime string: anytype) @Type(std.builtin.Type{
    .int = .{
        .bits = @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
        .signedness = .unsigned,
    },
}) {
    const byteLength = @bitSizeOf(@TypeOf(string.*)) / 8 - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}

const HEX_CHAR = blk: {
    var all = std.mem.zeroes([256]bool);
    for ('a'..('f' + 1)) |b| all[b] = true;
    for ('A'..('F' + 1)) |b| all[b] = true;
    for ('0'..('9' + 1)) |b| all[b] = true;
    break :blk all;
};

const HEX_DECODE = blk: {
    var all = std.mem.zeroes([256]u8);
    for ('a'..('z' + 1)) |b| all[b] = b - 'a' + 10;
    for ('A'..('Z' + 1)) |b| all[b] = b - 'A' + 10;
    for ('0'..('9' + 1)) |b| all[b] = b - '0';
    break :blk all;
};

const t = @import("t.zig");
test "url: parse" {
    {
        // absolute root
        const url = Url.parse("/");
        try t.expectString("/", url.raw);
        try t.expectString("/", url.path);
        try t.expectString("", url.query);
    }

    {
        // absolute path
        const url = Url.parse("/a/bc/def");
        try t.expectString("/a/bc/def", url.raw);
        try t.expectString("/a/bc/def", url.path);
        try t.expectString("", url.query);
    }

    {
        // absolute root with query
        const url = Url.parse("/?over=9000");
        try t.expectString("/?over=9000", url.raw);
        try t.expectString("/", url.path);
        try t.expectString("over=9000", url.query);
    }

    {
        // absolute root with empty query
        const url = Url.parse("/?");
        try t.expectString("/?", url.raw);
        try t.expectString("/", url.path);
        try t.expectString("", url.query);
    }

    {
        // absolute path with query
        const url = Url.parse("/hello/teg?duncan=idaho&ghanima=atreides");
        try t.expectString("/hello/teg?duncan=idaho&ghanima=atreides", url.raw);
        try t.expectString("/hello/teg", url.path);
        try t.expectString("duncan=idaho&ghanima=atreides", url.query);
    }
}

test "url: unescape" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var buffer: [10]u8 = undefined;

    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%a"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%1"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "123%45%6"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%zzzzz"));
    try t.expectError(error.InvalidEscapeSequence, Url.unescape(t.allocator, &buffer, "%0\xff"));

    var res = try Url.unescape(allocator, &buffer, "a+b");
    try t.expectString("a b", res.value);
    try t.expectEqual(true, res.buffered);

    res = try Url.unescape(allocator, &buffer, "a%20b");
    try t.expectString("a b", res.value);
    try t.expectEqual(true, res.buffered);

    const input = "%5C%C3%B6%2F%20%C3%A4%C3%B6%C3%9F%20~~.adas-https%3A%2F%2Fcanvas%3A123%2F%23ads%26%26sad";
    const expected = "\\ö/ äöß ~~.adas-https://canvas:123/#ads&&sad";
    res = try Url.unescape(allocator, &buffer, input);
    try t.expectString(expected, res.value);
    try t.expectEqual(false, res.buffered);
}

test "url: isValid" {
    var input: [600]u8 = undefined;
    for ([_]u8{ ' ', 'a', 'Z', '~' }) |c| {
        @memset(&input, c);
        for (0..input.len) |i| {
            try t.expectEqual(true, Url.isValid(input[0..i]));
        }
    }

    var r = t.getRandom();
    const random = r.random();

    for ([_]u8{ 31, 128, 0, 255 }) |c| {
        for (1..input.len) |i| {
            var slice = input[0..i];
            const idx = random.uintAtMost(usize, slice.len - 1);
            slice[idx] = c;
            try t.expectEqual(false, Url.isValid(slice));
            slice[idx] = 'a'; // revert this index to a valid value
        }
    }
}

test "toUint" {
    const ASCII_x = @as(u8, @bitCast([1]u8{'x'}));
    const ASCII_ab = @as(u16, @bitCast([2]u8{ 'a', 'b' }));
    const ASCII_xyz = @as(u24, @bitCast([3]u8{ 'x', 'y', 'z' }));
    const ASCII_abcd = @as(u32, @bitCast([4]u8{ 'a', 'b', 'c', 'd' }));

    try t.expectEqual(ASCII_x, asUint("x"));
    try t.expectEqual(ASCII_ab, asUint("ab"));
    try t.expectEqual(ASCII_xyz, asUint("xyz"));
    try t.expectEqual(ASCII_abcd, asUint("abcd"));

    try t.expectEqual(u8, @TypeOf(asUint("x")));
    try t.expectEqual(u16, @TypeOf(asUint("ab")));
    try t.expectEqual(u24, @TypeOf(asUint("xyz")));
    try t.expectEqual(u32, @TypeOf(asUint("abcd")));
}
