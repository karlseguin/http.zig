const std = @import("std");

// wrap a standard stream so that we can use a mock when testing
pub const Net = struct {
	stream: std.net.Stream,

	pub fn read(self: Net, buffer: []u8) !usize {
		return self.stream.read(buffer);
	}

	pub fn close(self: Net) void {
		return self.stream.close();
	}

	// Taken from io/Writer.zig (for writeAll) which calls the net.zig's Stream.write
	// function in this loop
	pub fn write(self: Net, data: []const u8) !void {
		var index: usize = 0;
		const el = std.event.Loop.instance.?;
		const h = self.stream.handle;
		while (index != data.len) {
			if (comptime std.io.is_async) {
				index += try el.write(h, data[index..], false);
			} else {
				index += try std.os.write(h, data[index..]);
			}
		}
	}
};
