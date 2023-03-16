const std = @import("std");
const t = @import("t.zig");

pub const Url = struct {
	raw: []const u8,
	path: []const u8,
	query: []const u8,

	const Self = @This();

	pub fn parse(raw: []const u8) Self {
		var path = raw;
		var query: []const u8 = "";

		if (std.mem.indexOfScalar(u8, raw, '?')) |index| {
			path = raw[0..index];
			query = raw[index+1..];
		}

		return .{
			.raw = raw,
			.path = path,
			.query = query,
		};
	}

	// the special "*" url, which is valid in HTTP OPTIONS request.
	pub fn star() Self {
		return .{
			.raw = "*",
			.path = "*",
			.query = "",
		};
	}
};

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
