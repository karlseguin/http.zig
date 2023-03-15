const std = @import("std");
const t = @import("t.zig");

pub const Url = struct {
	raw: []const u8,
	path: []const u8,
	query_string: ?[]const u8,

	const Self = @This();

	pub fn parse(raw: []const u8) Self {
		var path = raw;
		var query_string: ?[]const u8 = null;

		if (std.mem.indexOfScalar(u8, raw, '?')) |index| {
			path = raw[0..index];
			query_string = raw[index+1..];
		}

		return .{
			.raw = raw,
			.path = path,
			.query_string = query_string,
		};
	}

	// the special "*" url, which is valid in HTTP OPTIONS request.
	pub fn star() Self {
		return .{
			.raw = "*",
			.path = "*",
			.query_string = null,
		};
	}
};

test "url: parse" {
	{
		// absolute root
		const url = Url.parse("/");
		try t.expectString("/", url.raw);
		try t.expectString("/", url.path);
		try t.expectEqual(@as(?[]const u8, null), url.query_string);
	}

	{
		// absolute path
		const url = Url.parse("/a/bc/def");
		try t.expectString("/a/bc/def", url.raw);
		try t.expectString("/a/bc/def", url.path);
		try t.expectEqual(@as(?[]const u8, null), url.query_string);
	}

	{
		// absolute root with query_string
		const url = Url.parse("/?over=9000");
		try t.expectString("/?over=9000", url.raw);
		try t.expectString("/", url.path);
		try t.expectString("over=9000", url.query_string.?);
	}

	{
		// absolute root with empty query
		const url = Url.parse("/?");
		try t.expectString("/?", url.raw);
		try t.expectString("/", url.path);
		try t.expectString("", url.query_string.?);
	}

	{
		// absolute path with query_string
		const url = Url.parse("/hello/teg?duncan=idaho&ghanima=atreides");
		try t.expectString("/hello/teg?duncan=idaho&ghanima=atreides", url.raw);
		try t.expectString("/hello/teg", url.path);
		try t.expectString("duncan=idaho&ghanima=atreides", url.query_string.?);
	}
}
