const std = @import("std");
const builtin = @import("builtin");

const BORDER = "=" ** 80;

pub fn main() !void {
	const verbose = blk: {
		if (std.os.getenv("TEST_VERBOSE")) |e| {
			break :blk std.mem.eql(u8, e, "true");
		}
		break :blk false;
	};
	const filter = std.os.getenv("TEST_FILTER");

	const printer = Printer.init();
	var slowest = SlowTracker.init(5);
	defer slowest.deinit();

	var pass: usize = 0;
	var fail: usize = 0;
	var skip: usize = 0;
	var leak: usize = 0;

	for (builtin.test_functions) |t| {
		std.testing.allocator_instance = .{};
		var status = Status.pass;
		slowest.startTiming();

		const is_unnamed_test = std.mem.eql(u8, "test_0", t.name);
		if (filter) |f| {
			if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
				continue;
			}
		}

		const result = t.func();
		if (is_unnamed_test) {
			continue;
		}

		// strip out the test. prefix
		const friendly_name = t.name[5..];
		const ns_taken = slowest.endTiming(friendly_name);

		if (std.testing.allocator_instance.deinit() == .leak) {
			leak += 1;
			try printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{BORDER, friendly_name, BORDER});
		}

		if (result) |_| {
			pass += 1;
		} else |err| switch (err) {
			error.SkipZigTest => {
				skip += 1;
				status = .skip;
			},
			else => {
				status = .fail;
				fail += 1;
				try printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{BORDER, friendly_name, @errorName(err), BORDER});
				if (@errorReturnTrace()) |trace| {
					std.debug.dumpStackTrace(trace.*);
				}
			}
		}

		if (verbose) {
			const ms = @as(f64, @floatFromInt(ns_taken)) / 100_000.0;
			try printer.status(status, "{s} ({d:.2}ms)\n", .{friendly_name, ms});
		} else {
			try printer.status(status, ".", .{});
		}
	}

	const total_tests = pass + fail;
	const status = if (fail == 0) Status.pass else Status.fail;
	try printer.status(status, "\n{d} of {d} test{s} passed\n", .{pass, total_tests, if (total_tests != 1) "s" else ""});
	if (skip > 0) {
		try printer.status(.skip, "{d} test{s} skipped\n", .{skip, if (skip != 1) "s" else ""});
	}
	if (leak > 0) {
		try printer.status(.fail, "{d} test{s} leaked\n", .{leak, if (leak != 1) "s" else ""});
	}
	try printer.fmt("\n", .{});
	try slowest.display(printer);
	try printer.fmt("\n", .{});
	std.os.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
	out: std.fs.File.Writer,

	fn init() Printer {
		return .{
			.out = std.io.getStdErr().writer(),
		};
	}

	fn fmt(self: Printer, comptime format: []const u8, args: anytype) !void {
		return std.fmt.format(self.out, format, args);
	}

	fn status(self: Printer, s: Status, comptime format: []const u8, args: anytype) !void {
		const color = switch (s) {
			.pass => "\x1b[32m",
			.fail => "\x1b[31m",
			else => "",
		};
		const out = self.out;
		try out.writeAll(color);
		try std.fmt.format(out, format, args);
		return out.writeAll("\x1b[0m");
	}
};

const Status = enum {
	pass,
	fail,
	skip,
	text,
};

const SlowTracker = struct {
		const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
		max: usize,
		slowest: SlowestQueue,
		timer: std.time.Timer,

		fn init(count: u32) SlowTracker {
				const timer = std.time.Timer.start() catch @panic("failed to start timer");
				var slowest = SlowestQueue.init(std.heap.page_allocator, {});
				slowest.ensureTotalCapacity(count) catch @panic("OOM");
				return .{
						.max = count,
						.timer = timer,
						.slowest = slowest,
				};
		}

		const TestInfo = struct {
				ns: u64,
				name: []const u8,
		};

		fn deinit(self: SlowTracker) void {
				self.slowest.deinit();
		}

		fn startTiming(self: *SlowTracker) void {
			self.timer.reset();
		}

		fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
				var timer = self.timer;
				const ns = timer.lap();

				var slowest = &self.slowest;

				if (slowest.count() < self.max) {
						// Capacity is fixed to the # of slow tests we want to track
						// If we've tracked fewer tests than this capacity, than always add
						slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
						return ns;
				}

				{
						// Optimization to avoid shifting the dequeue for the common case
						// where the test isn't one of our slowest.
						const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
						if (fastest_of_the_slow.ns > ns) {
								// the test was faster than our fastest slow test, don't add
								return ns;
						}
				}

				// the previous fastest of our slow tests, has been pushed off.
				_ = slowest.removeMin();
				slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
				return ns;
		}

		fn display(self: *SlowTracker, printer: Printer) !void {
				var slowest = self.slowest;
				const count = slowest.count();
				try printer.fmt("Slowest {d} test{s}: \n", .{count, if (count != 1) "s" else ""});
				while (slowest.removeMinOrNull()) |info| {
						const ms = @as(f64, @floatFromInt(info.ns)) / 100_000.0;
						try printer.fmt("  {d:.2}ms\t{s}\n", .{ms, info.name});
				}
		}

		fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
				_ = context;
				return std.math.order(a.ns, b.ns);
		}
};
