const std = @import("std");
const builtin = @import("builtin");

pub fn maybeIgnoreSigpipe() void {
    const have_sigpipe_support = switch (builtin.os.tag) {
        .linux,
        .plan9,
        .solaris,
        .netbsd,
        .openbsd,
        .haiku,
        .macos,
        .ios,
        .watchos,
        .tvos,
        .dragonfly,
        .freebsd,
        => true,

        else => false,
    };

    if (have_sigpipe_support and !std.options.keep_sigpipe) {
        const posix = std.posix;
        const act: posix.Sigaction = .{
            // Set handler to a noop function instead of `SIG.IGN` to prevent
            // leaking signal disposition to a child process.
            .handler = .{ .handler = noopSigHandler },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        posix.sigaction(posix.SIG.PIPE, &act, null) catch |err|
            std.debug.panic("failed to set noop SIGPIPE handler: {s}", .{@errorName(err)});
    }
}

fn noopSigHandler(_: c_int) callconv(.C) void {}
