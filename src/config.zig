const httpz = @import("httpz.zig");
const request = @import("request.zig");
const response = @import("response.zig");


pub const Config = struct {

    // don't like using CPU detection since hyperthread cores are marketing.
    pub const DEFAULT_WORKERS = 2;

    port: ?u16 = null,
    address: ?[]const u8 = null,
    unix_path: ?[]const u8 = null,
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    cors: ?CORS = null,
    websocket: ?Websocket = null,
    thread_pool: ThreadPool = .{},

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
        request_count: ?u32 = null,
    };

    pub const CORS = struct {
        origin: []const u8,
        headers: ?[]const u8 = null,
        methods: ?[]const u8 = null,
        max_age: ?[]const u8 = null,
    };

    pub const Websocket = struct {
        max_size: usize = 65536,
        buffer_size: usize = 4096,
        handle_ping: bool = false,
        handle_pong: bool = false,
        handle_close: bool = false,
        large_buffer_pool_count: u16 = 8,
        large_buffer_size: usize = 32768,
    };

    pub fn threadPoolCount(self: *const Config) u32 {
        const thread_count = self.thread_pool.count orelse 4;

        // In blockingMode, we only have 1 worker (regardless of the
        // config). We want to make blocking and nonblocking modes
        // use the same number of threads, so we'll convert extra workers
        // into thread pool threads.
        // In blockingMode, the worker does relatively little work, and the
        // thread pool threads do more, so this re-balancing makes some sense
        // and can always be opted out of by explicitly setting
        // config.workers.count = 1

        if (httpz.blockingMode()) {
            const worker_count = self.workerCount();
            if (worker_count > 1) {
                return thread_count + worker_count - 1;
            }
        }

        return thread_count;
    }

    pub fn workerCount(self: *const Config) u32 {
        if (httpz.blockingMode()) {
            return 1;
        }
        return self.workers.count orelse DEFAULT_WORKERS;
    }
};
