const std = @import("std");
const request = @import("request.zig");

// Wraps a socket with a application-specific details, such as information needed
// to manage the connection's lifecycle (e.g. timeouts). Conns are placed in a
// linked list, hence the next/prev.
// The Conn contains request and response state information necessary to operate
// in nonblocking mode. A pointer to the conn is the userdata passed to epoll/kqueue.
// Should only be created through the worker's ConnPool
pub const Conn = struct {
	stream: std.net.Stream,
	address: std.net.Address,
	last_request: i64,
	req_state: request.State,
	next: ?*Conn = null,
	prev: ?*Conn = null,

	pub fn deinit(conn: *Conn, allocator: std.mem.Allocator) void {
		conn.req_state.deinit(allocator);
	}
};
