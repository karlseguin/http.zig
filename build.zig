const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_opts = .{ .target = target, .optimize = optimize };
    const metrics_module = b.dependency("metrics", dep_opts).module("metrics");
    const websocket_module = b.dependency("websocket", dep_opts).module("websocket");

    const httpz_module = b.addModule("httpz", .{
        .root_source_file = b.path("src/httpz.zig"),
        .imports = &.{
            .{ .name = "metrics", .module = metrics_module },
            .{ .name = "websocket", .module = websocket_module },
        },
    });
    {
        const options = b.addOptions();
        options.addOption(bool, "httpz_blocking", false);
        httpz_module.addOptions("build", options);
    }

    {
        // demo
        const exe = b.addExecutable(.{
            .name = "http.zig demo",
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("httpz", httpz_module);
        exe.root_module.addImport("metrics", metrics_module);
        exe.root_module.addImport("websocket", websocket_module);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const tests = b.addTest(.{
            .root_source_file = b.path("src/httpz.zig"),
            .target = target,
            .optimize = optimize,
            .test_runner = b.path("test_runner.zig"),
        });
        tests.linkLibC();
        const force_blocking = b.option(bool, "force_blocking", "Force blocking mode") orelse false;
        {
            const options = b.addOptions();
            options.addOption(bool, "httpz_blocking", force_blocking);
            tests.root_module.addOptions("build", options);
        }
        {
            const options = b.addOptions();
            options.addOption(bool, "websocket_blocking", force_blocking);
            websocket_module.addOptions("build", options);
        }

        tests.root_module.addImport("metrics", metrics_module);
        tests.root_module.addImport("websocket", websocket_module);
        const run_test = b.addRunArtifact(tests);
        run_test.has_side_effects = true;

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_test.step);
    }
}
