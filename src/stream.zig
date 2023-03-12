const std = @import("std");

// wrap a standard stream so that we can use a mock when testing
pub const Stream = struct {
	stream: std.net.Stream,

	const Self = @This();

	pub fn read(self: Self, buffer: []u8) !usize {
		const h = self.stream.handle;
		if (std.io.is_async) {
			return std.event.Loop.instance.?.read(h, buffer, false);
		} else {
			return std.os.read(h, buffer);
		}
	}

	pub fn close(self: Self) void {
		return self.stream.close();
	}

	// Taken from io/Writer.zig (for writeAll) which calls the net.zig's Stream.write
	// function in this loop
	pub fn write(self: Self, data: []const u8) !void {
		var index: usize = 0;
		const h = self.stream.handle;
		if (comptime std.io.is_async) {
			const el = std.event.Loop.instance.?;
			while (index != data.len) {
				index += try el.write(h, data[index..], false);
			}
		} else {
			while (index != data.len) {
				index += try std.os.write(h, data[index..]);
			}
		}
	}
};
