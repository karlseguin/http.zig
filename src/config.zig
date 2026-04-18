const std = @import("std");
const httpz = @import("httpz.zig");
const request = @import("request.zig");
const response = @import("response.zig");
const posix_shim = @import("posix_shim.zig");
const io_shim = @import("io_shim.zig");

/// Caller-supplied parsed address variant (0.16's `std.Io.net.IpAddress`).
/// Kept as the public `.addr` variant type so existing user literals like
/// `.addr = .{ .ip4 = .{ .bytes = ..., .port = ... } }` continue to compile.
const IpAddr = std.Io.net.IpAddress;

pub const Config = struct {
    address: AddressConfig = .localhost(5882),
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    thread_pool: ThreadPool = .{},
    websocket: Websocket = .{},

    pub const AddressConfig = union(enum) {
        ip: IpAddress,
        unix: []const u8,
        addr: IpAddr,

        pub fn localhost(port: u16) AddressConfig {
            return .{ .addr = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } } };
        }

        pub fn all(port: u16) AddressConfig {
            return .{ .addr = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } } };
        }
    };

    pub const IpAddress = struct {
        host: []const u8,
        port: u16,
    };

    pub const ThreadPool = struct {
        count: ?u16 = null,
        backlog: ?u32 = null,
        buffer_size: ?usize = null,
    };

    pub const Worker = struct {
        count: ?u16 = null,
        max_conn: ?u16 = null,
        min_conn: ?u16 = null,
        large_buffer_count: ?u16 = null,
        large_buffer_size: ?u32 = null,
        retain_allocated_bytes: ?usize = null,
    };

    pub const Request = struct {
        lazy_read_size: ?usize = null,
        max_body_size: ?usize = null,
        buffer_size: ?usize = null,
        max_header_count: ?usize = null,
        max_param_count: ?usize = null,
        max_query_count: ?usize = null,
        max_form_count: ?usize = null,
        max_multiform_count: ?usize = null,
    };

    pub const Response = struct {
        max_header_count: ?usize = null,
    };

    pub const Timeout = struct {
        request: ?u32 = null,
        keepalive: ?u32 = null,
        request_count: ?usize = null,
    };

    pub const Websocket = struct {
        max_message_size: ?usize = null,
        small_buffer_size: ?usize = null,
        small_buffer_pool: ?usize = null,
        large_buffer_size: ?usize = null,
        large_buffer_pool: ?u16 = null,
        compression: bool = false,
        compression_retain_writer: bool = true,
        compression_write_treshold: ?usize = null,
    };

    pub fn parseAddress(self: *const Config) !posix_shim.Address {
        return switch (self.address) {
            .ip => |i| try posix_shim.Address.parseIp(i.host, i.port),
            .unix => |unix_path| b: {
                if (comptime std.Io.net.has_unix_sockets == false) {
                    break :b error.UnixPathNotSupported;
                }
                // Best-effort cleanup of a stale socket file; ignore errors
                // (file may not exist yet).
                std.Io.Dir.deleteFileAbsolute(io_shim.stdio(), unix_path) catch {};
                break :b try posix_shim.Address.initUnix(unix_path);
            },
            .addr => |a| posix_shim.Address.fromIpAddress(a),
        };
    }

    pub fn isUnixAddress(config: *const Config) bool {
        return switch (config.address) {
            .unix => true,
            .ip, .addr => false,
        };
    }

    pub fn threadPoolCount(self: *const Config) u32 {
        return self.thread_pool.count orelse 32;
    }

    pub fn workerCount(self: *const Config) u32 {
        if (httpz.blockingMode()) {
            return 1;
        }
        return self.workers.count orelse 1;
    }
};
