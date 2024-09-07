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

    const examples = [_]struct{
        file: []const u8,
        name: []const u8,
        libc: bool = false,
    } {
        .{.file = "examples/01_basic.zig", .name = "example_1"},
        .{.file = "examples/02_handler.zig", .name = "example_2"},
        .{.file = "examples/03_dispatch.zig", .name = "example_3"},
        .{.file = "examples/04_action_context.zig", .name = "example_4"},
        .{.file = "examples/05_request_takeover.zig", .name = "example_5"},
        .{.file = "examples/06_middleware.zig", .name = "example_6"},
        .{.file = "examples/07_advanced_routing.zig", .name = "example_7"},
        .{.file = "examples/08_websocket.zig", .name = "example_8"},
        .{.file = "examples/09_shutdown.zig", .name = "example_9", .libc = true},
    };

    {
       for (examples) |ex| {
            const exe = b.addExecutable(.{
                .name = ex.name,
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path(ex.file),
            });
            exe.root_module.addImport("httpz", httpz_module);
            exe.root_module.addImport("metrics", metrics_module);
            if (ex.libc) {
                exe.linkLibC();
            }
            b.installArtifact(exe);

            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }

            const run_step = b.step(ex.name, ex.file);
            run_step.dependOn(&run_cmd.step);
        }
    }
}
