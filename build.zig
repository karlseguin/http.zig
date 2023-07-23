const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpz_module = b.addModule("httpz", .{
        .source_file = .{ .path = "src/httpz.zig" },
    });

    // setup executable
    const exe = b.addExecutable(.{
        .name = "http.zig demo",
        .root_source_file = .{ .path = "example/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("httpz", httpz_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // setup tests
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_test = b.addTest(.{
        .root_source_file = .{ .path = "src/httpz.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_test = b.addRunArtifact(lib_test);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);
}
