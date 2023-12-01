const std = @import("std");

const request = @import("request.zig");

const Self = @This();

pub const Conn = struct {
	stream: std.net.Stream,
	last_request: i64,
	address: std.net.Address,
	reader: request.Reader,
	req_state: *request.State,
	next: ?*Conn = null,
	prev: ?*Conn = null,

	pub const List = Self.List;
};

const List = struct {
	len: usize = 0,
	head: ?*Conn = null,
	tail: ?*Conn = null,

	pub fn insert(self: *List, node: *Conn) void {
		if (self.tail) |tail| {
			tail.next = node;
			node.prev = tail;
			self.tail = node;
		} else {
			self.head = node;
			self.tail = node;
		}
		self.len += 1;
		node.next = null;
	}

	pub fn remove(self: *List, node: *Conn) void {
		if (node.prev) |prev| {
			prev.next = node.next;
		} else {
			self.head = node.next;
		}

		if (node.next) |next| {
			next.prev = node.prev;
		} else {
			self.tail = node.prev;
		}
		self.len -= 1;
	}
};
