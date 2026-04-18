// Custom test runner — ported to Zig 0.16.
//
// Usage in build.zig:
//   const tests = b.addTest(.{
//      .root_module = $MODULE_BEING_TESTED,
//      .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
//   });
//
// 0.16 changes from the 0.15 version of this runner:
//   * `main` now takes `std.process.Init.Minimal` (entry-point signature).
//   * Env var reads go through `init.environ.block.view()` — `std.process.getEnvVarOwned`
//     was removed.
//   * Timer replaced with `std.Io.Timestamp` — `std.time.Timer` was removed.
//   * `PriorityDequeue.init(alloc, {})` → `.empty` + allocator threaded through method calls.
//   * `std.debug.dumpStackTrace` signature changed to take a `*const std.debug.StackTrace`
//     rather than a `*builtin.StackTrace`.

pub const std_options = std.Options{ .log_scope_levels = &[_]std.log.ScopeLevel{
    .{ .scope = .websocket, .level = .warn },
} };

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// used in the custom panic handler
var current_test: ?[]const u8 = null;

// Process-wide Io for the runner. Initialized once from main's Init.Minimal;
// used by CompatTimer and by any test code that pulls io via io_shim.
var runner_threaded: std.Io.Threaded = undefined;
var runner_io_set: bool = false;
fn runnerIo() std.Io {
    std.debug.assert(runner_io_set);
    return runner_threaded.io();
}

pub fn main(init: std.process.Init.Minimal) !void {
    runner_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    runner_io_set = true;

    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fba.allocator();

    const env = Env.init(allocator, &init.environ);
    defer env.deinit(allocator);

    var slowest = SlowTracker.init(allocator, 5);
    defer slowest.deinit(allocator);

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(t);
        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
                continue;
            }
        }

        const friendly_name = blk: {
            const name = t.name;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test")) {
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
            }
            break :blk name;
        };

        current_test = friendly_name;
        std.testing.allocator_instance = .{};
        const result = t.func();
        current_test = null;

        const ns_taken = slowest.endTiming(allocator, friendly_name);

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
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
                Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
                if (@errorReturnTrace()) |trace| {
                    // 0.16: use `dumpErrorReturnTrace` which accepts the
                    // `*builtin.StackTrace` returned by `@errorReturnTrace()`
                    // directly. The older `dumpStackTrace` now takes a
                    // `*const std.debug.StackTrace` with a different layout.
                    std.debug.dumpErrorReturnTrace(trace);
                }
                if (env.fail_first) {
                    break;
                }
            },
        }

        if (env.verbose) {
            const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
            Printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
        } else {
            Printer.status(status, ".", .{});
        }
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});
    // 0.16: std.posix.exit was removed. Use std.process.exit which wraps
    // the underlying syscall via std.c.exit / std.os.linux.exit_group.
    std.process.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

// 0.16 removed `std.time.Timer`. Replacement uses `std.Io.Timestamp`, which
// reads the monotonic clock via the process Io. Same semantics as the old
// Timer: `start` captures a start instant, `reset` re-captures it, `lap`
// returns ns since last reset and re-captures.
const CompatTimer = struct {
    start_ns: i96,

    fn start() CompatTimer {
        return .{ .start_ns = std.Io.Timestamp.now(runnerIo(), .awake).nanoseconds };
    }

    fn reset(self: *CompatTimer) void {
        self.start_ns = std.Io.Timestamp.now(runnerIo(), .awake).nanoseconds;
    }

    fn lap(self: *CompatTimer) u64 {
        const now_ns = std.Io.Timestamp.now(runnerIo(), .awake).nanoseconds;
        const delta = now_ns - self.start_ns;
        self.start_ns = now_ns;
        return if (delta < 0) 0 else @intCast(delta);
    }
};

const SlowTracker = struct {
    // 0.16 PriorityDequeue is now unmanaged; allocator is passed to methods.
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    timer: CompatTimer,

    fn init(allocator: Allocator, count: u32) SlowTracker {
        var slowest = SlowestQueue.empty;
        slowest.ensureTotalCapacity(allocator, count) catch @panic("OOM");
        return .{
            .max = count,
            .timer = CompatTimer.start(),
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker, allocator: Allocator) void {
        self.slowest.deinit(allocator);
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer.reset();
    }

    fn endTiming(self: *SlowTracker, allocator: Allocator, test_name: []const u8) u64 {
        var timer = self.timer;
        const ns = timer.lap();

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            slowest.push(allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                return ns;
            }
        }

        _ = slowest.popMin();
        slowest.push(allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.popMin()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    fn init(allocator: Allocator, environ: *const std.process.Environ) Env {
        return .{
            .verbose = readEnvBool(allocator, environ, "TEST_VERBOSE", true),
            .fail_first = readEnvBool(allocator, environ, "TEST_FAIL_FIRST", false),
            .filter = readEnv(allocator, environ, "TEST_FILTER"),
        };
    }

    fn deinit(self: Env, allocator: Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    // 0.16: look up via Init.Minimal.environ rather than the removed
    // `std.process.getEnvVarOwned`. Returned slice is duped into `allocator`
    // so the caller can free without aliasing process-lifetime memory.
    fn readEnv(allocator: Allocator, environ: *const std.process.Environ, key: []const u8) ?[]const u8 {
        if (comptime builtin.os.tag == .windows) return null;
        const view = environ.block.view();
        for (view.slice) |entry_ptr| {
            const entry = std.mem.span(entry_ptr);
            if (entry.len <= key.len) continue;
            if (entry[key.len] != '=') continue;
            if (!std.mem.eql(u8, entry[0..key.len], key)) continue;
            const value = entry[key.len + 1 ..];
            return allocator.dupe(u8, value) catch null;
        }
        return null;
    }

    fn readEnvBool(allocator: Allocator, environ: *const std.process.Environ, key: []const u8, deflt: bool) bool {
        const value = readEnv(allocator, environ, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
