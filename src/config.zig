const std = @import("std");

const posix = @import("posix.zig");
const httpz = @import("httpz.zig");
const request = @import("request.zig");
const response = @import("response.zig");

const Io = std.Io;

pub const Config = struct {
    address: Address = .localhost(5882),
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    thread_pool: ThreadPool = .{},
    websocket: Websocket = .{},

    pub const Address = union(enum) {
        ip: Io.net.IpAddress,
        unix: []const u8,

        pub fn localhost(port: u16) Address {
            return .{ .ip = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } } };
        }

        pub fn all(port: u16) Address {
            return .{ .ip = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } } };
        }

        pub fn toPosix(address: Address, io: Io) !posix.Address {
            switch (address) {
                .unix => |path| {
                    if (comptime Io.net.has_unix_sockets == false) {
                        return error.UnixPathNotSupported;
                    }
                    // Best-effort cleanup of a stale socket file; ignore errors
                    // (file may not exist yet).
                    Io.Dir.deleteFileAbsolute(io, path) catch {};
                    return posix.Address.initUnix(path);
                },
                .ip => |ip| switch (ip) {
                    .ip4 => |ip4| return posix.Address.initIp4(ip4.bytes, ip4.port),
                    .ip6 => |ip6| return posix.Address.initIp6(ip6.bytes, ip6.port, ip6.flow, ip6.interface.index),
                },
            }
        }
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
