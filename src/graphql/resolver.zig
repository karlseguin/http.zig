const std = @import("std");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;

/// Helper to create a resolver from a simple function
pub fn makeResolver(
    comptime func: anytype,
) types.ResolverFn {
    const Wrapper = struct {
        fn resolve(ctx: *anyopaque) anyerror!types.Value {
            _ = ctx;
            return @call(.auto, func, .{});
        }
    };
    return Wrapper.resolve;
}

/// Helper to create a resolver that returns a string
pub fn stringResolver(comptime str: []const u8) types.ResolverFn {
    const Wrapper = struct {
        fn resolve(ctx: *anyopaque) anyerror!types.Value {
            _ = ctx;
            return types.Value{ .string = str };
        }
    };
    return Wrapper.resolve;
}

/// Helper to create a resolver that returns an integer
pub fn intResolver(comptime value: i64) types.ResolverFn {
    const Wrapper = struct {
        fn resolve(ctx: *anyopaque) anyerror!types.Value {
            _ = ctx;
            return types.Value{ .int = value };
        }
    };
    return Wrapper.resolve;
}

/// Helper to create a resolver that returns a boolean
pub fn boolResolver(comptime value: bool) types.ResolverFn {
    const Wrapper = struct {
        fn resolve(ctx: *anyopaque) anyerror!types.Value {
            _ = ctx;
            return types.Value{ .boolean = value };
        }
    };
    return Wrapper.resolve;
}

/// Helper to create a resolver that returns null
pub fn nullResolver() types.ResolverFn {
    const Wrapper = struct {
        fn resolve(ctx: *anyopaque) anyerror!types.Value {
            _ = ctx;
            return types.Value.null_value;
        }
    };
    return Wrapper.resolve;
}
