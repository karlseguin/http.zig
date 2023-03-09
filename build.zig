const std = @import("std");

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

		const httpzig_module = b.addModule("httpzig", .{
				.source_file = .{ .path = "src/http.zig" },
		});

		const lib = b.addStaticLibrary(.{
				.name = "httpzig",
				.root_source_file = .{ .path = "src/http.zig" },
				.target = target,
				.optimize = optimize,
		});
		lib.install();

	// setup executable
	const exe = b.addExecutable(.{
		.name = "http.zig demo",
		.root_source_file = .{ .path = "example/main.zig" },
		.target = target,
		.optimize = optimize,
	});
	exe.addModule("httpzig", httpzig_module);
	exe.install();

	const run_cmd = exe.run();
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cmd.addArgs(args);
	}

	// setup tests
	const run_step = b.step("run", "Run the app");
	run_step.dependOn(&run_cmd.step);

	const tests = b.addTest(.{
		.root_source_file = .{ .path = "src/http.zig" },
		.target = target,
		.optimize = optimize,
	});

	const test_step = b.step("test", "Run tests");
	test_step.dependOn(&tests.step);
}
