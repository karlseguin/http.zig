const std = @import("std");
const builtin = @import("builtin");
pub const websocket = @import("websocket");

pub const testing = @import("testing.zig");

pub const routing = @import("router.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const key_value = @import("key_value.zig");

pub const Router = routing.Router;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Url = @import("url.zig").Url;
pub const Config = @import("config.zig").Config;

const Thread = std.Thread;
const fd_t = std.posix.fd_t;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const log = std.log.scoped(.httpz);

const worker = @import("worker.zig");
const Conn = worker.Conn;
const ThreadPool = @import("thread_pool.zig").ThreadPool;

const build = @import("build");
const force_blocking: bool = if (@hasDecl(build, "force_blocking")) build.force_blocking else false;

const MAX_REQUEST_COUNT = 4_294_967_295;

pub fn writeMetrics(writer: anytype) !void {
    return @import("metrics.zig").write(writer);
}

pub const Protocol = enum {
    HTTP10,
    HTTP11,
};

pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    OPTIONS,
};

pub const ContentType = enum {
    BINARY,
    CSS,
    CSV,
    EOT,
    EVENTS,
    GIF,
    GZ,
    HTML,
    ICO,
    JPG,
    JS,
    JSON,
    OTF,
    PDF,
    PNG,
    SVG,
    TAR,
    TEXT,
    TTF,
    WASM,
    WEBP,
    WOFF,
    WOFF2,
    XML,
    UNKNOWN,

    const JS_BIT = @as(u16, @bitCast([2]u8{ 'j', 's' }));
    const GZ_BIT = @as(u16, @bitCast([2]u8{ 'g', 'z' }));
    const CSS_BIT = @as(u24, @bitCast([3]u8{ 'c', 's', 's' }));
    const CSV_BIT = @as(u24, @bitCast([3]u8{ 'c', 's', 'v' }));
    const EOT_BIT = @as(u24, @bitCast([3]u8{ 'e', 'o', 't' }));
    const GIF_BIT = @as(u24, @bitCast([3]u8{ 'g', 'i', 'f' }));
    const HTM_BIT = @as(u24, @bitCast([3]u8{ 'h', 't', 'm' }));
    const ICO_BIT = @as(u24, @bitCast([3]u8{ 'i', 'c', 'o' }));
    const JPG_BIT = @as(u24, @bitCast([3]u8{ 'j', 'p', 'g' }));
    const OTF_BIT = @as(u24, @bitCast([3]u8{ 'o', 't', 'f' }));
    const PDF_BIT = @as(u24, @bitCast([3]u8{ 'p', 'd', 'f' }));
    const PNG_BIT = @as(u24, @bitCast([3]u8{ 'p', 'n', 'g' }));
    const SVG_BIT = @as(u24, @bitCast([3]u8{ 's', 'v', 'g' }));
    const TAR_BIT = @as(u24, @bitCast([3]u8{ 't', 'a', 'r' }));
    const TTF_BIT = @as(u24, @bitCast([3]u8{ 't', 't', 'f' }));
    const XML_BIT = @as(u24, @bitCast([3]u8{ 'x', 'm', 'l' }));
    const JPEG_BIT = @as(u32, @bitCast([4]u8{ 'j', 'p', 'e', 'g' }));
    const JSON_BIT = @as(u32, @bitCast([4]u8{ 'j', 's', 'o', 'n' }));
    const HTML_BIT = @as(u32, @bitCast([4]u8{ 'h', 't', 'm', 'l' }));
    const TEXT_BIT = @as(u32, @bitCast([4]u8{ 't', 'e', 'x', 't' }));
    const WASM_BIT = @as(u32, @bitCast([4]u8{ 'w', 'a', 's', 'm' }));
    const WOFF_BIT = @as(u32, @bitCast([4]u8{ 'w', 'o', 'f', 'f' }));
    const WEBP_BIT = @as(u32, @bitCast([4]u8{ 'w', 'e', 'b', 'p' }));
    const WOFF2_BIT = @as(u40, @bitCast([5]u8{ 'w', 'o', 'f', 'f', '2' }));

    pub fn forExtension(ext: []const u8) ContentType {
        if (ext.len == 0) return .UNKNOWN;
        const temp = if (ext[0] == '.') ext[1..] else ext;
        if (temp.len > 5) return .UNKNOWN;

        var normalized: [5]u8 = undefined;
        for (temp, 0..) |c, i| {
            normalized[i] = std.ascii.toLower(c);
        }

        switch (temp.len) {
            2 => {
                switch (@as(u16, @bitCast(normalized[0..2].*))) {
                    JS_BIT => return .JS,
                    GZ_BIT => return .GZ,
                    else => return .UNKNOWN,
                }
            },
            3 => {
                switch (@as(u24, @bitCast(normalized[0..3].*))) {
                    CSS_BIT => return .CSS,
                    CSV_BIT => return .CSV,
                    EOT_BIT => return .EOT,
                    GIF_BIT => return .GIF,
                    HTM_BIT => return .HTML,
                    ICO_BIT => return .ICO,
                    JPG_BIT => return .JPG,
                    OTF_BIT => return .OTF,
                    PDF_BIT => return .PDF,
                    PNG_BIT => return .PNG,
                    SVG_BIT => return .SVG,
                    TAR_BIT => return .TAR,
                    TTF_BIT => return .TTF,
                    XML_BIT => return .XML,
                    else => return .UNKNOWN,
                }
            },
            4 => {
                switch (@as(u32, @bitCast(normalized[0..4].*))) {
                    JPEG_BIT => return .JPG,
                    JSON_BIT => return .JSON,
                    HTML_BIT => return .HTML,
                    TEXT_BIT => return .TEXT,
                    WASM_BIT => return .WASM,
                    WOFF_BIT => return .WOFF,
                    WEBP_BIT => return .WEBP,
                    else => return .UNKNOWN,
                }
            },
            5 => {
                switch (@as(u40, @bitCast(normalized[0..5].*))) {
                    WOFF2_BIT => return .WOFF2,
                    else => return .UNKNOWN,
                }
            },
            else => return .UNKNOWN,
        }
        return .UNKNOWN;
    }

    pub fn forFile(file_name: []const u8) ContentType {
        return forExtension(std.fs.path.extension(file_name));
    }
};

pub fn Action(comptime G: type) type {
    if (G == void) {
        return *const fn (*Request, *Response) anyerror!void;
    }
    return *const fn (G, *Request, *Response) anyerror!void;
}

pub fn Dispatcher(comptime G: type, comptime R: type) type {
    if (G == void and R == void) {
        return *const fn (Action(void), *Request, *Response) anyerror!void;
    } else if (G == void) {
        return *const fn (Action(R), *Request, *Response) anyerror!void;
    } else if (R == void) {
        return *const fn (G, Action(G), *Request, *Response) anyerror!void;
    }
    return *const fn (G, Action(R), *Request, *Response) anyerror!void;
}

pub fn DispatchableAction(comptime G: type, comptime R: type) type {
    return struct {
        ctx: G,
        action: Action(R),
        dispatcher: Dispatcher(G, R),
    };
}

fn ErrorHandlerAction(comptime G: type) type {
    if (G == void) {
        return *const fn (*Request, *Response, anyerror) void;
    }
    return *const fn (G, *Request, *Response, anyerror) void;
}

// Done this way so that Server and ServerCtx have a similar API
pub fn Server() type {
    return struct {
        pub fn init(allocator: Allocator, config: Config) !ServerCtx(void, void) {
            return try ServerCtx(void, void).init(allocator, config, {});
        }
    };
}

pub fn ServerCtx(comptime G: type, comptime R: type) type {
    return struct {
        const TP = if (blockingMode()) ThreadPool(worker.Blocking(*Self).handleConnection) else ThreadPool(Self.notifyingHandler);

        ctx: G,
        config: Config,
        allocator: Allocator,
        _cors_origin: ?[]const u8,
        _router: Router(G, R),
        _errorHandler: ErrorHandlerAction(G),
        _notFoundHandler: Action(G),
        _cond: Thread.Condition,
        _thread_pool: *TP,
        _signals: [][2]fd_t,
        _max_request_per_connection: u64,

        const Self = @This();

        pub fn init(allocator: Allocator, config: Config, ctx: G) !Self {
            const nfh = if (comptime G == void) defaultNotFound else defaultNotFoundWithContext;
            const erh = if (comptime G == void) defaultErrorHandler else defaultErrorHandlerWithContext;
            const dd = if (comptime G == void) defaultDispatcher else defaultDispatcherWithContext;

            var var_config = config;
            if (config.port == null) {
                var_config.port = 5882;
            }
            if (config.address == null) {
                var_config.address = "127.0.0.1";
            }

            var thread_pool = try TP.init(allocator, .{
                .count = config.threadPoolCount(),
                .backlog = config.thread_pool.backlog orelse 500,
                .buffer_size = config.thread_pool.buffer_size orelse 8192,
            });
            errdefer thread_pool.deinit();

            const signals = try allocator.alloc([2]fd_t, config.workers.count orelse Config.DEFAULT_WORKERS);
            errdefer allocator.free(signals);

            return .{
                .ctx = ctx,
                .config = var_config,
                .allocator = allocator,
                ._cond = .{},
                ._signals = signals,
                ._errorHandler = erh,
                ._notFoundHandler = nfh,
                ._thread_pool = thread_pool,
                ._router = try Router(G, R).init(allocator, dd, ctx),
                ._cors_origin = if (config.cors) |cors| cors.origin else null,
                ._max_request_per_connection = config.timeout.request_count orelse MAX_REQUEST_COUNT,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self._signals);
            self._router.deinit(self.allocator);
            self._thread_pool.deinit();
        }

        pub fn dispatchUndefined(_: *Self) Dispatcher(G, R) {
            return struct{
                fn dispatch(ctx: G, action: Action(R), req: *Request, res: *Response) !void {
                    _ = ctx;
                    return action(undefined, req, res);
                }
            }.dispatch;
        }

        pub fn listen(self: *Self) !void {
            const net = std.net;
            const posix = std.posix;
            const config = self.config;

            var no_delay = true;
            const address = blk: {
                if (config.unix_path) |unix_path| {
                    if (comptime builtin.os.tag == .windows) {
                        return error.UnixPathNotSupported;
                    }
                    no_delay = false;
                    std.fs.deleteFileAbsolute(unix_path) catch {};
                    break :blk try net.Address.initUnix(unix_path);
                } else {
                    const listen_port = config.port.?;
                    const listen_address = config.address.?;
                    break :blk try net.Address.parseIp(listen_address, listen_port);
                }
            };

            const socket = blk: {
                var sock_flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
                if (blockingMode() == false) sock_flags |= posix.SOCK.NONBLOCK;

                const proto = if (address.any.family == posix.AF.UNIX) @as(u32, 0) else posix.IPPROTO.TCP;
                break :blk try posix.socket(address.any.family, sock_flags, proto);
            };

            if (no_delay) {
                // TODO: Broken on darwin:
                // https://github.com/ziglang/zig/issues/17260
                // if (@hasDecl(os.TCP, "NODELAY")) {
                //  try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
                // }
                try posix.setsockopt(socket, posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
            }

            if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
                try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
            } else if (@hasDecl(posix.SO, "REUSEPORT")) {
                try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            } else {
                try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            }

            {
                const socklen = address.getOsSockLen();
                try posix.bind(socket, &address.any, socklen);
                try posix.listen(socket, 1204); // kernel backlog
            }
            defer posix.close(socket);

            const allocator = self.allocator;

            const ws_config = config.websocket orelse Config.Websocket{};
            var ws = try websocket.Server.init(allocator, .{
                .max_size = ws_config.max_size,
                .buffer_size = ws_config.buffer_size,
                .handle_ping = ws_config.handle_ping,
                .handle_pong = ws_config.handle_pong,
                .handle_close = ws_config.handle_close,
                .large_buffer_pool_count = ws_config.large_buffer_pool_count,
                .large_buffer_size = ws_config.large_buffer_size,
            });
            defer ws.deinit(allocator);

            if (comptime blockingMode()) {
                var w = try worker.Blocking(*Self).init(allocator, self, &ws, &config);
                defer w.deinit();

                const thrd = try Thread.spawn(.{}, worker.Blocking(*Self).listen, .{&w, socket});

                // is this really the best way?
                var mutex = Thread.Mutex{};
                mutex.lock();
                self._cond.wait(&mutex);
                mutex.unlock();
                w.stop();
                thrd.join();
            } else {
                const Worker = worker.NonBlocking(*Self);
                var signals = self._signals;
                const worker_count = config.workers.count orelse Config.DEFAULT_WORKERS;
                const workers = try allocator.alloc(Worker, worker_count);
                const threads = try allocator.alloc(Thread, worker_count);

                var started: usize = 0;

                defer {
                    for (0..started) |i| {
                        posix.close(signals[i][1]);
                        threads[i].join();
                        workers[i].deinit();
                    }
                    allocator.free(workers);
                    allocator.free(threads);
                }

                for (0..workers.len) |i| {
                    signals[i] = try posix.pipe2(.{.NONBLOCK = true});
                    errdefer posix.close(signals[i][1]);

                    workers[i] = try Worker.init(allocator, i, self, &ws, &config);
                    errdefer workers[i].deinit();

                    threads[i] = try Thread.spawn(.{}, Worker.run, .{ &workers[i], socket, signals[i][0] });
                    started += 1;
                }

                // is this really the best way?
                var mutex = Thread.Mutex{};
                mutex.lock();
                self._cond.wait(&mutex);
                mutex.unlock();
            }
        }

        pub fn listenInNewThread(self: *Self) !std.Thread {
            return try std.Thread.spawn(.{}, listen, .{self});
        }

        pub fn stop(self: *Self) void {
            self._cond.signal();
        }

        pub fn notFound(self: *Self, nfa: Action(G)) void {
            self._notFoundHandler = nfa;
        }

        pub fn errorHandler(self: *Self, eha: ErrorHandlerAction(G)) void {
            self._errorHandler = eha;
        }

        pub fn dispatcher(self: *Self, d: Dispatcher(G, R)) void {
            (&self._router).dispatcher(d);
        }

        pub fn router(self: *Self) *Router(G, R) {
            return &self._router;
        }

        fn defaultNotFoundWithContext(_: G, req: *Request, res: *Response) !void {
            try defaultNotFound(req, res);
        }

        fn defaultNotFound(_: *Request, res: *Response) !void {
            res.status = 404;
            res.body = "Not Found";
        }

        fn defaultErrorHandlerWithContext(_: G, req: *Request, res: *Response, err: anyerror) void {
            defaultErrorHandler(req, res, err);
        }

        fn defaultErrorHandler(req: *Request, res: *Response, err: anyerror) void {
            res.status = 500;
            res.body = "Internal Server Error";
            std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{ req.url.raw, err });
        }

        fn defaultDispatcher(action: Action(R), req: *Request, res: *Response) !void {
            try action(req, res);
        }

        fn defaultDispatcherWithContext(ctx: G, action: Action(R), req: *Request, res: *Response) !void {
            if (R == G) {
                return action(ctx, req, res);
            }
            // app needs to provide a dispatcher in this case
            return error.CannotDispatch;
        }

        pub fn notifyingHandler(self: *Self, w: *worker.NonBlocking(*Self), conn: *Conn, thread_buf: []u8) void {
            self.handler(conn, thread_buf);
            const signal = self._signals[w.id][1];
            const buf = std.mem.asBytes(&@intFromPtr(conn));

            var to_write: usize = @sizeOf(usize);
            while (to_write > 0) {
                to_write -= std.posix.write(signal, buf) catch @panic("TODO");
            }
        }

        // This is always called from within a threadpool thread. For nonblocking,
        // notifyingHandler (above) was the threadpool's main entry and it called this.
        // For blocking, the threadpool was directed to the worker's handleConnection
        // which eventually called this.
        // thread_buf is a thread-specific configurable-sized buffer that we're
        // free to use as we want. This is, by far, the most efficient memory
        // we can use because it's allocated on server start and re-used on
        // each request (which is safe, because, in blocking or nonblocking, once
        // a request reaches this point, processing is blocking from the point
        // of view of the server).
        // We'll use thread_buf as part of a FallBackAllocator with the conn
        // arena for our request ONLY. We cannot use thread_buf for the response
        // because the response data must outlive the execution of this function
        // (and thus, in nonblocking, outlives this threadpool's execution unit).
        pub fn handler(self: *Self, conn: *Conn, thread_buf: []u8) void {
            const aa = conn.arena.allocator();

            var fba = FixedBufferAllocator.init(thread_buf);
            var fb = FallbackAllocator{
                .fba = &fba,
                .fallback = aa,
                .fixed = fba.allocator(),
            };
            var req = Request.init(fb.allocator(), conn);
            var res = Response.init(aa, conn);

            if (comptime hasHandle(G)) {
                @call(.auto, G.handle, .{self.ctx, &req, &res});
            } else {
                const dispatchable_action = self._router.route(req.method, req.url.path, &req.params);
                self.dispatch(dispatchable_action, &req, &res) catch |err| {
                    if (comptime G == void) {
                        self._errorHandler(&req, &res, err);
                    } else {
                        const ctx = if (dispatchable_action) |da| da.ctx else self.ctx;
                        self._errorHandler(ctx, &req, &res, err);
                    }
                };
            }

            if (res.disowned) {
                conn.handover = .disown;
            } else  blk: {
                if (res.chunked) {
                    conn.stream.writeAll("\r\n0\r\n\r\n") catch {
                        conn.handover = .close;
                        break :blk;
                    };
                }
                const request_count_limit = conn.request_count == self._max_request_per_connection;
                if (request_count_limit == false and req.canKeepAlive()) {
                    conn.handover = if (res.written == true) .keepalive else .write_and_keepalive;
                } else {
                    res.keepalive = false;
                    conn.handover = if (res.written == true) .close else .write_and_close;
                }
                if (res.written == false) {
                    conn.res_state.prepareForWrite(&res) catch |err| {
                        log.err("Failed to prepare response for writing: {}", .{err});
                        conn.handover = .close;
                    };
                }
            }
        }

        inline fn dispatch(self: *const Self, dispatchable_action: ?DispatchableAction(G, R), req: *Request, res: *Response) !void {
            if (self._cors_origin) |origin| {
                res.header("Access-Control-Allow-Origin", origin);
            }
            if (dispatchable_action) |da| {
                if (G == void) {
                    return da.dispatcher(da.action, req, res);
                }
                return da.dispatcher(da.ctx, da.action, req, res);
            }

            if (req.method == .OPTIONS) {
                if (self.config.cors) |config| {
                    if (req.header("sec-fetch-mode")) |mode| {
                        if (std.mem.eql(u8, mode, "cors")) {
                            if (config.headers) |headers| {
                                res.header("Access-Control-Allow-Headers", headers);
                            }
                            if (config.methods) |methods| {
                                res.header("Access-Control-Allow-Methods", methods);
                            }
                            if (config.max_age) |max_age| {
                                res.header("Access-Control-Max-Age", max_age);
                            }
                            res.status = 204;
                            return;
                        }
                    }
                }
            }

            if (G == void) {
                return self._notFoundHandler(req, res);
            }
            return self._notFoundHandler(self.ctx, req, res);
        }
    };
}

fn hasHandle(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Struct =>  return @hasDecl(T, "handle"),
        .Pointer => |ptr| return hasHandle(ptr.child),
        else => return false,
    }
}

pub fn blockingMode() bool {
    if (force_blocking) {
        return true;
    }
    return switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => false,
        else => true,
    };
}

const t = @import("t.zig");
var la = std.heap.GeneralPurposeAllocator(.{}){};

var default_server: *ServerCtx(void, void) = undefined;
var context_server: *ServerCtx(u32, u32) = undefined;
var cors_server: *ServerCtx(u32, u32) = undefined;
var reuse_server: *ServerCtx(void, void) = undefined;
var handle_server: *ServerCtx(CustomHandler, CustomHandler) = undefined;

pub fn upgradeWebsocket(comptime H: type, req: *Request, res: *Response, context: anytype) !bool {
    const key = ensureWebsocketRequest(req) orelse return false;

    const conn = res.conn;
    const stream = conn.stream;
    try conn.blocking();
    res.disown();

    try websocket.Handshake.reply(key, stream);

    const thread = try std.Thread.spawn(.{}, websocketHandler, .{ H, conn.websocket, stream, context });
    thread.detach();
    return true;
}

fn ensureWebsocketRequest(req: *Request) ?[]const u8 {
    const upgrade = req.header("upgrade") orelse return null;
    if (std.ascii.eqlIgnoreCase(upgrade, "websocket") == false) return null;

    const version = req.header("sec-websocket-version") orelse return null;
    if (std.ascii.eqlIgnoreCase(version, "13") == false) return null;

    // firefox will send multiple values for this header
    const connection = req.header("connection") orelse return null;
    if (std.ascii.indexOfIgnoreCase(connection, "upgrade") == null) return null;

    return req.header("sec-websocket-key");
}

fn websocketHandler(comptime H: type, server: *websocket.Server, stream: std.net.Stream, context: anytype) void {
    errdefer stream.close();
    var conn = server.newConn(stream);
    var handler = H.init(&conn, context) catch return;
    server.handle(H, &handler, &conn);
}

// std.heap.StackFallbackAllocator is weird. First, it requires a comptime buffer
// size (why?) second, it relies on private functions of the FixedBufferAllocator (why?)
// So we write our own that doesn't have these limitations.
const FallbackAllocator = struct {
    fixed: Allocator,
    fallback: Allocator,
    fba: *FixedBufferAllocator,

    pub fn allocator(self: *FallbackAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ra: usize) ?[*]u8 {
        const self: *FallbackAllocator = @ptrCast(@alignCast(ctx));
        return self.fixed.rawAlloc(len, ptr_align, ra) orelse self.fallback.rawAlloc(len, ptr_align, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ra: usize) bool {
        const self: *FallbackAllocator = @ptrCast(@alignCast(ctx));
        if (self.fba.ownsPtr(buf.ptr)) {
            if (self.fixed.rawResize(buf, buf_align, new_len, ra)) {
                return true;
            }
        }
        return self.fallback.rawResize(buf, buf_align, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ra: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ra;
        // hack.
        // Always noop since, in our specific usage, we know fallback is an arena.
    }
};

test {
    // this will leak since the server will run until the process exits. If we use
    // our testing allocator, it'll report the leak.
    const leaking_allocator = la.allocator();
    {
        default_server = try leaking_allocator.create(ServerCtx(void, void));
        default_server.* = try Server().init(leaking_allocator, .{ .port = 5992 });
        var router = default_server.router();
        router.get("/test/ws", testWS);
        router.get("/test/json", testJsonRes);
        router.get("/test/query", testReqQuery);
        router.get("/test/stream", testEventStream);
        router.get("/test/chunked", testChunked);
        router.get("/test/callback", testCallback);
        router.allC("/test/dispatcher", testDispatcherAction, .{ .dispatcher = testDispatcher1 });
        var thread = try default_server.listenInNewThread();
        thread.detach();
    }

    {
        context_server = try leaking_allocator.create(ServerCtx(u32, u32));
        context_server.* = try ServerCtx(u32, u32).init(leaking_allocator, .{ .port = 5993 }, 3);
        context_server.notFound(testNotFound);
        var router = context_server.router();
        router.get("/", ctxEchoAction);
        router.get("/write/*", ctxEchoActionWrite);
        router.get("/fail", testFail);
        router.post("/login", ctxEchoAction);
        router.get("/test/body/cl", testCLBody);
        router.get("/test/headers", testHeaders);
        router.all("/api/:version/users/:UserId", testParams);

        var admin_routes = router.group("/admin/", .{ .dispatcher = ctxTestDispatcher2, .ctx = 99 });
        admin_routes.get("/users", ctxEchoAction);
        admin_routes.put("/users/:id", ctxEchoAction);

        var debug_routes = router.group("/debug", .{ .dispatcher = ctxTestDispatcher3, .ctx = 20 });
        debug_routes.head("/ping", ctxEchoAction);
        debug_routes.options("/stats", ctxEchoAction);

        var thread = try context_server.listenInNewThread();
        thread.detach();
    }

    {
        cors_server = try leaking_allocator.create(ServerCtx(u32, u32));
        cors_server.* = try ServerCtx(u32, u32).init(leaking_allocator, .{
            .port = 5994,
            .cors = .{ .origin = "httpz.local", .headers = "content-type", .methods = "GET,POST", .max_age = "300" },
        }, 100);
        var router = cors_server.router();
        router.all("/echo", ctxEchoAction);
        var thread = try cors_server.listenInNewThread();
        thread.detach();
    }

    {
        // with only 1 worker, and a min/max conn of 1, each request should
        // hit our reset path.
        reuse_server = try leaking_allocator.create(ServerCtx(void, void));
        reuse_server.* = try Server().init(leaking_allocator, .{
            .port = 5995,
            .response = .{ .body_buffer_size = 100 },
            .workers = .{.count = 1, .min_conn = 1, .max_conn = 1}
        });
        var router = reuse_server.router();
        router.get("/test/writer", testWriter);
        var thread = try reuse_server.listenInNewThread();
        thread.detach();
    }

    {
        handle_server = try leaking_allocator.create(ServerCtx(CustomHandler, CustomHandler));
        handle_server.* = try ServerCtx(CustomHandler, CustomHandler).init(leaking_allocator, .{
            .port = 5996,
            .response = .{ .body_buffer_size = 100 },
        }, CustomHandler{});
        var thread = try handle_server.listenInNewThread();
        thread.detach();
    }

    std.testing.refAllDecls(@This());
}

test "httpz: invalid request" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("TEA / HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "httpz: invalid request path" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("TEA /helo\rn\nWorld:test HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "httpz: invalid header name" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nOver: 9000\r\nHel\tlo:World\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "httpz: no route" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 404 \r\nContent-Length: 9\r\n\r\nNot Found", testReadAll(stream, &buf));
}

test "httpz: no route with custom notFound handler" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /not_found HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 404 \r\nCtx: 3\r\nContent-Length: 10\r\n\r\nwhere lah?", testReadAll(stream, &buf));
}

test "httpz: unhandled exception" {
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /fail HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 500 \r\nContent-Length: 21\r\n\r\nInternal Server Error", testReadAll(stream, &buf));
}

test "httpz: unhandled exception with custom error handler" {
    // should not be done like this, server isn't thread safe and shouldn't
    // be changed once listening, but greatly simplifies our testing.
    context_server.errorHandler(testErrorHandler);

    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /fail HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 500 \r\nCtx: 3\r\nContent-Length: 29\r\n\r\n#/why/arent/tags/hierarchical", testReadAll(stream, &buf));
}

test "httpz: route params" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /api/v2/users/9001 HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 20\r\n\r\nversion=v2,user=9001", testReadAll(stream, &buf));
}

test "httpz: request and response headers" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /test/headers HTTP/1.1\r\nHeader-Name: Header-Value\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nCtx: 3\r\nEcho: Header-Value\r\nother: test-value\r\nContent-Length: 0\r\n\r\n", testReadAll(stream, &buf));
}

test "httpz: content-length body" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /test/body/cl HTTP/1.1\r\nHeader-Name: Header-Value\r\nContent-Length: 4\r\n\r\nabcz");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nEcho-Body: abcz\r\nContent-Length: 0\r\n\r\n", testReadAll(stream, &buf));
}

test "httpz: json response" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/json HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 201 \r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"over\":9000,\"teg\":\"soup\"}", testReadAll(stream, &buf));
}

test "httpz: query" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/query?fav=keemun%20te%61%21 HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 11\r\n\r\nkeemun tea!", testReadAll(stream, &buf));
}

test "httpz: chunked" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/chunked HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [1000]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nOver: 9000!\r\nTransfer-Encoding: chunked\r\n\r\n7\r\nChunk 1\r\n11\r\nand another chunk\r\n0\r\n\r\n", testReadAll(stream, &buf));
}

test "httpz: custom dispatcher" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("HEAD /test/dispatcher HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\ndispatcher: test-dispatcher-1\r\nContent-Length: 6\r\n\r\naction", testReadAll(stream, &buf));
}

test "httpz: router groups" {
    const stream = testStream(5993);
    defer stream.close();

    {
        try stream.writeAll("GET / HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .ctx = 3, .method = "GET", .path = "/" });
        try t.expectEqual(true, res.headers.get("dispatcher") == null);
    }

    {
        try stream.writeAll("GET /admin/users HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .ctx = 99, .method = "GET", .path = "/admin/users" });
        try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("PUT /admin/users/:id HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .ctx = 99, .method = "PUT", .path = "/admin/users/:id" });
        try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("HEAD /debug/ping HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .ctx = 20, .method = "HEAD", .path = "/debug/ping" });
        try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("OPTIONS /debug/stats HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .ctx = 20, .method = "OPTIONS", .path = "/debug/stats" });
        try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("POST /login HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .ctx = 3, .method = "POST", .path = "/login" });
        try t.expectEqual(true, res.headers.get("dispatcher") == null);
    }
}

test "httpz: CORS" {
    const stream = testStream(5994);
    defer stream.close();

    {
        try stream.writeAll("GET /echo HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();
        try t.expectEqual(true, res.headers.get("Access-Control-Max-Age") == null);
        try t.expectEqual(true, res.headers.get("Access-Control-Allow-Methods") == null);
        try t.expectEqual(true, res.headers.get("Access-Control-Allow-Headers") == null);
        try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
    }

    {
        // non-cors options
        try stream.writeAll("OPTIONS /echo HTTP/1.1\r\nSec-Fetch-Mode: navigate\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try t.expectEqual(true, res.headers.get("Access-Control-Max-Age") == null);
        try t.expectEqual(true, res.headers.get("Access-Control-Allow-Methods") == null);
        try t.expectEqual(true, res.headers.get("Access-Control-Allow-Headers") == null);
        try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
    }

    {
        // cors request
        try stream.writeAll("OPTIONS /no_route HTTP/1.1\r\nSec-Fetch-Mode: cors\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
        try t.expectString("GET,POST", res.headers.get("Access-Control-Allow-Methods").?);
        try t.expectString("content-type", res.headers.get("Access-Control-Allow-Headers").?);
        try t.expectString("300", res.headers.get("Access-Control-Max-Age").?);
    }
}

test "httpz: writer re-use" {
    defer t.reset();

    const stream = testStream(5995);
    defer stream.close();

    var expected: [10]TestUser = undefined;

    var buf: [100]u8 = undefined;
    for (0..10) |i| {
        expected[i] = .{
            .id = try std.fmt.allocPrint(t.arena.allocator(), "id-{d}", .{i}),
            .power = i,
        };
        try stream.writeAll(try std.fmt.bufPrint(&buf, "GET /test/writer?count={d} HTTP/1.1\r\nContent-Length: 0\r\n\r\n", .{i+1}));

        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .data = expected[0..i+1]});
    }
}

test "ContentType: forX" {
    inline for (@typeInfo(ContentType).Enum.fields) |field| {
        if (comptime std.mem.eql(u8, "BINARY", field.name)) continue;
        if (comptime std.mem.eql(u8, "EVENTS", field.name)) continue;
        try t.expectEqual(@field(ContentType, field.name), ContentType.forExtension(field.name));
        try t.expectEqual(@field(ContentType, field.name), ContentType.forExtension("." ++ field.name));
        try t.expectEqual(@field(ContentType, field.name), ContentType.forFile("some_file." ++ field.name));
    }
    // variations
    try t.expectEqual(ContentType.HTML, ContentType.forExtension(".htm"));
    try t.expectEqual(ContentType.JPG, ContentType.forExtension(".jpeg"));

    try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(".spice"));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(""));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forExtension(".x"));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile(""));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("css"));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("css"));
    try t.expectEqual(ContentType.UNKNOWN, ContentType.forFile("must.spice"));
}

test "httpz: event stream" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/stream HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();

    try t.expectEqual(818, res.status);
    try t.expectEqual(true, res.headers.get("Content-Length") == null);
    try t.expectString("text/event-stream", res.headers.get("Content-Type").?);
    try t.expectString("no-cache", res.headers.get("Cache-Control").?);
    try t.expectString("keep-alive", res.headers.get("Connection").?);
    try t.expectString("helloa message", res.body);
}

test "websocket: invalid request" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/ws HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();
    try t.expectString("invalid websocket", res.body);
}

test "websocket: upgrade" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/ws HTTP/1.1\r\nContent-Length: 0\r\n");
    try stream.writeAll("upgrade: WEBsocket\r\n");
    try stream.writeAll("Sec-Websocket-verSIon: 13\r\n");
    try stream.writeAll("ConnectioN: abc,upgrade,123\r\n");
    try stream.writeAll("SEC-WEBSOCKET-KeY: a-secret-key\r\n\r\n");

    var res = testReadHeader(stream);
    defer res.deinit();
    try t.expectEqual(101, res.status);
    try t.expectString("websocket", res.headers.get("Upgrade").?);
    try t.expectString("upgrade", res.headers.get("Connection").?);
    try t.expectString("55eM2SNGu+68v5XXrr982mhPFkU=", res.headers.get("Sec-Websocket-Accept").?);

    try stream.writeAll(&websocket.frameText("over 9000!"));
    try stream.writeAll(&websocket.frameBin("close"));

    var pos: usize = 0;
    var buf: [20]u8 = undefined;
    while (pos < 12) {
        const n = try stream.read(buf[pos..]);
        if (n == 0) {
            break;
        }
        pos += n;
    }

    try t.expectEqual(12, pos);
    try t.expectEqual(129, buf[0]);
    try t.expectEqual(10, buf[1]);
    try t.expectString("over 9000!", buf[2..12]);
}

test "httpz: keepalive" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /api/v2/users/9001 HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 20\r\n\r\nversion=v2,user=9001", testReadAll(stream, &buf));

    try stream.writeAll("GET /api/v2/users/123 HTTP/1.1\r\n\r\n");
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 19\r\n\r\nversion=v2,user=123", testReadAll(stream, &buf));
}

test "httpz: keepalive with explicit write" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /write/9001 HTTP/1.1\r\n\r\n");

    var buf: [1000]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 45\r\n\r\n{\"ctx\":3,\"method\":\"GET\",\"path\":\"/write/9001\"}", testReadAll(stream, &buf));

    try stream.writeAll("GET /write/123 HTTP/1.1\r\n\r\n");
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 44\r\n\r\n{\"ctx\":3,\"method\":\"GET\",\"path\":\"/write/123\"}", testReadAll(stream, &buf));
}

test "httpz: request in chunks" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /api/v2/use");
    std.time.sleep(std.time.ns_per_ms * 10);
    try stream.writeAll("rs/11 HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 18\r\n\r\nversion=v2,user=11", testReadAll(stream, &buf));
}

test "httpz: callback" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/callback HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 3\r\n\r\nres", testReadAll(stream, &buf));
}

test "httpz: dispatcher handle" {
    const stream = testStream(5996);
    defer stream.close();
    try stream.writeAll("GET /whatever?name=teg HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 9\r\n\r\nhello teg", testReadAll(stream, &buf));
}

fn testFail(_: u32, _: *Request, _: *Response) !void {
    return error.TestUnhandledError;
}

fn testParams(_: u32, req: *Request, res: *Response) !void {
    const args = .{ req.param("version").?, req.param("UserId").? };
    res.body = try std.fmt.allocPrint(req.arena, "version={s},user={s}", args);
}

fn testHeaders(ctx: u32, req: *Request, res: *Response) !void {
    addContextHeader(res, ctx);
    res.header("Echo", req.header("header-name").?);
    res.header("other", "test-value");
}

fn testCLBody(_: u32, req: *Request, res: *Response) !void {
    res.header("Echo-Body", req.body().?);
}

fn testWS(req: *Request, res: *Response) !void {
    if (try upgradeWebsocket(TestWSHandler, req, res, TestWSHandler.Context{ .id = 339 }) == false) {
        res.body = "invalid websocket";
    }
}

fn testJsonRes(_: *Request, res: *Response) !void {
    res.status = 201;
    try res.json(.{ .over = 9000, .teg = "soup" }, .{});
}

fn testEventStream(_: *Request, res: *Response) !void {
    res.status = 818;
    try res.startEventStream(StreamContext{.data = "hello"}, StreamContext.handle);
}

const CallbackState = struct {
    body: []const u8,
};

fn testCallback(_: *Request, res: *Response) !void {
    const state = try t.allocator.create(CallbackState);
    state.body = try t.allocator.dupe(u8, "res");

    res.body = state.body;
    res.callback(testCallbackClean, @ptrCast(state));
}

fn testCallbackClean(state: *anyopaque) void {
    const cs: *CallbackState = @alignCast(@ptrCast(state));
    t.allocator.free(cs.body);
    t.allocator.destroy(cs);
}

const StreamContext = struct {
    data: []const u8,

    fn handle(self: StreamContext, stream: std.net.Stream) void {
        stream.writeAll(self.data) catch unreachable;
        stream.writeAll("a message") catch unreachable;
    }
};

fn testReqQuery(req: *Request, res: *Response) !void {
    res.status = 200;
    const query = try req.query();
    res.body = query.get("fav").?;
}

fn testChunked(_: *Request, res: *Response) !void {
    res.header("Over", "9000!");
    res.status = 200;
    try res.chunk("Chunk 1");
    try res.chunk("and another chunk");
}

fn testNotFound(ctx: u32, _: *Request, res: *Response) !void {
    res.status = 404;
    addContextHeader(res, ctx);
    res.body = "where lah?";
}

fn testErrorHandler(ctx: u32, _: *Request, res: *Response, _: anyerror) void {
    res.status = 500;
    addContextHeader(res, ctx);
    res.body = "#/why/arent/tags/hierarchical";
}

fn addContextHeader(res: *Response, ctx: u32) void {
    const value = std.fmt.allocPrint(res.arena, "{d}", .{ctx}) catch unreachable;
    res.header("Ctx", value);
}

fn testDispatcherAction(_: *Request, res: *Response) !void {
    return res.directWriter().writeAll("action");
}

fn testDispatcher1(action: Action(void), req: *Request, res: *Response) !void {
    res.header("dispatcher", "test-dispatcher-1");
    return action(req, res);
}

fn ctxTestDispatcher2(ctx: u32, action: Action(u32), req: *Request, res: *Response) !void {
    res.header("dispatcher", "test-dispatcher-2");
    return action(ctx, req, res);
}

fn ctxTestDispatcher3(ctx: u32, action: Action(u32), req: *Request, res: *Response) !void {
    res.header("dispatcher", "test-dispatcher-3");
    return action(ctx, req, res);
}

fn ctxEchoAction(ctx: u32, req: *Request, res: *Response) !void {
    return res.json(.{
        .ctx = ctx,
        .method = @tagName(req.method),
        .path = req.url.path,
    }, .{});
}

fn ctxEchoActionWrite(ctx: u32, req: *Request, res: *Response) !void {
    var arr = std.ArrayList(u8).init(res.arena);
    try std.json.stringify(.{
        .ctx = ctx,
        .method = @tagName(req.method),
        .path = req.url.path,
    }, .{}, arr.writer());

    res.body = arr.items;
    return res.write();
}

fn testWriter(req: *Request, res: *Response) !void {
    res.status = 200;
    const query = try req.query();
    const count = try std.fmt.parseInt(u16, query.get("count").?, 10);

    var data = try res.arena.alloc(TestUser, count);
    for (0..count) |i| {
        data[i] = .{
            .id = try std.fmt.allocPrint(res.arena, "id-{d}", .{i}),
            .power = i,
        };
    }
    return res.json(.{.data = data}, .{});
}

fn testStream(port: u16) std.net.Stream {
    const timeout = std.mem.toBytes(std.posix.timeval{
        .tv_sec = 0,
        .tv_usec = 20_000,
    });

    const address = std.net.Address.parseIp("127.0.0.1", port) catch unreachable;
    const stream = std.net.tcpConnectToAddress(address) catch unreachable;
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout) catch unreachable;
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout) catch unreachable;
    return stream;
}

fn testReadAll(stream: std.net.Stream, buf: []u8) []u8 {
    var pos: usize = 0;
    var blocked = false;
    while (true) {
        std.debug.assert(pos < buf.len);
        const n = stream.read(buf[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (blocked) return buf[0..pos];
                blocked = true;
                std.time.sleep(std.time.ns_per_ms);
                continue;
            },
            else => @panic(@errorName(err)),
        };
        if (n == 0) {
            return buf[0..pos];
        }
        pos += n;
        blocked = false;
    }
    unreachable;
}

fn testReadParsed(stream: std.net.Stream) testing.Testing.Response {
    var buf: [4096]u8 = undefined;
    const data = testReadAll(stream, &buf);
    return testing.parse(data) catch unreachable;
}

fn testReadHeader(stream: std.net.Stream) testing.Testing.Response {
    var pos: usize = 0;
    var blocked = false;
    var buf: [1024]u8 = undefined;
    while (true) {
        std.debug.assert(pos < buf.len);
        const n = stream.read(buf[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (blocked) unreachable;
                blocked = true;
                std.time.sleep(std.time.ns_per_ms);
                continue;
            },
            else => @panic(@errorName(err)),
        };

        if (n == 0) unreachable;

        pos += n;
        if (std.mem.endsWith(u8, buf[0..pos], "\r\n\r\n")) {
            return testing.parse(buf[0..pos]) catch unreachable;
        }
        blocked = false;
    }
    unreachable;
}

const TestWSHandler = struct {
    ctx: TestWSHandler.Context,
    conn: *websocket.Conn,

    const Context = struct {
        id: i32,
    };

    pub fn init(conn: *websocket.Conn, ctx: TestWSHandler.Context) !TestWSHandler {
        return .{
            .ctx = ctx,
            .conn = conn,
        };
    }

    pub fn handle(self: *TestWSHandler, msg: websocket.Message) !void {
        if (msg.type == .binary) {
            self.conn.close();
        } else {
            try self.conn.write(msg.data);
        }
    }

    pub fn close(_: *TestWSHandler) void {}
};

const TestUser = struct {
    id: []const u8,
    power: usize,
};

const CustomHandler = struct {
    fn handle(_: CustomHandler, req: *Request, res: *Response) void {
        const query = req.query() catch unreachable;
        std.fmt.format(res.writer(), "hello {s}", .{query.get("name") orelse "world"}) catch unreachable;
    }
};
