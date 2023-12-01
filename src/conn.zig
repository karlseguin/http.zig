const std = @import("std");
const request = @import("request.zig");

pub const Conn = struct {
	stream: std.net.Stream,
	last_request: i64,
	address: std.net.Address,
	reader: request.Reader,
	req_state: *request.State,
	next: ?*Conn = null,
	prev: ?*Conn = null,

	pub const List = LinkList(Conn);
};

fn LinkList(comptime T: type) type {
	return struct {
		len: usize = 0,
		head: ?*T = null,
		tail: ?*T = null,

		const Self = @This();

		pub fn insert(self: *Self, node: *T) void {
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

		pub fn remove(self: *Self, node: *T) void {
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
}

const t = @import("t.zig");
test "Conn: LinkList" {
	var list = LinkList(TestNode){};
	try expectList(&.{}, list);

	var n1 = TestNode{.id = 1};
	list.insert(&n1);
	try expectList(&.{1}, list);

	list.remove(&n1);
	try expectList(&.{}, list);

	var n2 = TestNode{.id = 2};
	list.insert(&n2);
	list.insert(&n1);
	try expectList(&.{2, 1}, list);

	var n3 = TestNode{.id = 3};
	list.insert(&n3);
	try expectList(&.{2, 1, 3}, list);

	list.remove(&n1);
	try expectList(&.{2, 3}, list);

	list.insert(&n1);
	try expectList(&.{2, 3, 1}, list);

	list.remove(&n2);
	try expectList(&.{3, 1}, list);

	list.remove(&n1);
	try expectList(&.{3}, list);

	list.remove(&n3);
	try expectList(&.{}, list);
}

const TestNode = struct {
	id: i32,
	next: ?*TestNode = null,
	prev: ?*TestNode = null,
};

fn expectList(expected: []const i32, list: LinkList(TestNode)) !void {
	if (expected.len == 0) {
		try t.expectEqual(null, list.head);
		try t.expectEqual(null, list.tail);
		return;
	}

	var i: usize = 0;
	var next = list.head;
	while (next) |node| {
		try t.expectEqual(expected[i], node.id);
		i += 1;
		next = node.next;
	}
	try t.expectEqual(expected.len, i);

	i = expected.len;
	var prev = list.tail;
	while (prev) |node| {
		i -= 1;
		try t.expectEqual(expected[i], node.id);
		prev = node.prev;
	}
	try t.expectEqual(0, i);
}
