const std = @import("std");
const httpz = @import("httpz.zig");
const request = @import("request.zig");
const response = @import("response.zig");

const Address = std.net.Address;

pub const Config = struct {
    address: AddressConfig = .default,
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    thread_pool: ThreadPool = .{},
    websocket: Websocket = .{},

    pub const AddressConfig = union(enum) {
        default, // Default is 127.0.0.1:5882.
        ip: IpAddress,
        unix: []const u8,
        addr: Address,

        pub fn localhost(port: u16) AddressConfig {
            return .{ .addr = .initIp4(.{ 127, 0, 0, 1 }, port) };
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

    pub fn parseAddress(self: *const Config) !Address {
        return switch (self.address) {
            .default => .initIp4(.{ 127, 0, 0, 1 }, 5882),
            .ip => |i| try .parseIp(i.host, i.port),
            .unix => |unix_path| b: {
                if (comptime std.net.has_unix_sockets == false) {
                    break :b error.UnixPathNotSupported;
                }
                std.fs.deleteFileAbsolute(unix_path) catch {};
                break :b try .initUnix(unix_path);
            },
            .addr => |a| a,
        };
    }

    pub fn isUnixAddress(config: *const Config) bool {
        return switch (config.address) {
            .unix => true,
            .ip, .default => false,
            .addr => |a| a.any.family == std.posix.AF.UNIX,
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
