const std = @import("std");
const builtin = @import("builtin");

pub const testing = @import("testing.zig");
pub const websocket = @import("websocket");

pub const routing = @import("router.zig");
pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const key_value = @import("key_value.zig");
pub const middleware = @import("middleware/middleware.zig");

pub const Router = routing.Router;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Url = @import("url.zig").Url;
pub const Config = @import("config.zig").Config;

const Thread = std.Thread;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const log = std.log.scoped(.httpz);

const worker = @import("worker.zig");
const HTTPConn = worker.HTTPConn;

const build = @import("build");
const force_blocking: bool = if (@hasDecl(build, "httpz_blocking")) build.httpz_blocking else false;

const MAX_REQUEST_COUNT = std.math.maxInt(usize);

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
    CONNECT,
    OTHER,
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

    const asUint = @import("url.zig").asUint;

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
                    asUint("js") => return .JS,
                    asUint("gz") => return .GZ,
                    else => return .UNKNOWN,
                }
            },
            3 => {
                switch (@as(u24, @bitCast(normalized[0..3].*))) {
                    asUint("css") => return .CSS,
                    asUint("csv") => return .CSV,
                    asUint("eot") => return .EOT,
                    asUint("gif") => return .GIF,
                    asUint("htm") => return .HTML,
                    asUint("ico") => return .ICO,
                    asUint("jpg") => return .JPG,
                    asUint("otf") => return .OTF,
                    asUint("pdf") => return .PDF,
                    asUint("png") => return .PNG,
                    asUint("svg") => return .SVG,
                    asUint("tar") => return .TAR,
                    asUint("ttf") => return .TTF,
                    asUint("xml") => return .XML,
                    else => return .UNKNOWN,
                }
            },
            4 => {
                switch (@as(u32, @bitCast(normalized[0..4].*))) {
                    asUint("jpeg") => return .JPG,
                    asUint("json") => return .JSON,
                    asUint("html") => return .HTML,
                    asUint("text") => return .TEXT,
                    asUint("wasm") => return .WASM,
                    asUint("woff") => return .WOFF,
                    asUint("webp") => return .WEBP,
                    else => return .UNKNOWN,
                }
            },
            5 => {
                switch (@as(u40, @bitCast(normalized[0..5].*))) {
                    asUint("woff2") => return .WOFF2,
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

// When we initialize our Server(handler: type) with a non-void handler,
// the ActionContext will either be defined by the handler or it'll be the
// handler itself. So, for this type, "ActionContext" can be either
// the Handler or ActionContext from the Server.
pub fn Action(comptime ActionContext: type) type {
    if (ActionContext == void) {
        return *const fn (*Request, *Response) anyerror!void;
    }
    return *const fn (ActionContext, *Request, *Response) anyerror!void;
}

pub fn Dispatcher(comptime Handler: type, comptime ActionArg: type) type {
    if (Handler == void) {
        return *const fn (Action(void), *Request, *Response) anyerror!void;
    }
    return *const fn (Handler, ActionArg, *Request, *Response) anyerror!void;
}

pub fn DispatchableAction(comptime Handler: type, comptime ActionArg: type) type {
    return struct {
        data: ?*const anyopaque,
        handler: Handler,
        action: ActionArg,
        dispatcher: Dispatcher(Handler, ActionArg),
        middlewares: []const Middleware(Handler) = &.{},
    };
}

pub fn Middleware(comptime H: type) type {
    return struct {
        ptr: *anyopaque,
        deinitFn: *const fn (ptr: *anyopaque) void,
        executeFn: *const fn (ptr: *anyopaque, req: *Request, res: *Response, executor: *Server(H).Executor) anyerror!void,

        const Self = @This();

        pub fn init(ptr: anytype) Self {
            const T = @TypeOf(ptr);
            const ptr_info = @typeInfo(T);

            const gen = struct {
                pub fn deinit(pointer: *anyopaque) void {
                    const self: T = @ptrCast(@alignCast(pointer));
                    if (std.meta.hasMethod(T, "deinit")) {
                        return ptr_info.pointer.child.deinit(self);
                    }
                }

                pub fn execute(pointer: *anyopaque, req: *Request, res: *Response, executor: *Server(H).Executor) anyerror!void {
                    const self: T = @ptrCast(@alignCast(pointer));
                    return ptr_info.pointer.child.execute(self, req, res, executor);
                }
            };

            return .{
                .ptr = ptr,
                .deinitFn = gen.deinit,
                .executeFn = gen.execute,
            };
        }

        pub fn deinit(self: Self) void {
            self.deinitFn(self.ptr);
        }

        pub fn execute(self: Self, req: *Request, res: *Response, executor: *Server(H).Executor) !void {
            return self.executeFn(self.ptr, req, res, executor);
        }
    };
}

// When no WebsocketHandler is specified, we give it a dummy handler just to get
// the code to compile.
pub const DummyWebsocketHandler = struct {
    pub fn clientMessage(_: DummyWebsocketHandler, _: []const u8) !void {}
};

pub const MiddlewareConfig = struct {
    arena: Allocator,
    allocator: Allocator,
};

pub fn Server(comptime H: type) type {
    const Handler = switch (@typeInfo(H)) {
        .@"struct" => H,
        .pointer => |ptr| ptr.child,
        .void => void,
        else => @compileError("Server handler must be a struct, got: " ++ @tagName(@typeInfo(H))),
    };

    const ActionArg = if (comptime std.meta.hasFn(Handler, "dispatch")) @typeInfo(@TypeOf(Handler.dispatch)).@"fn".params[1].type.? else Action(H);

    const has_websocket = Handler != void and @hasDecl(Handler, "WebsocketHandler");
    const WebsocketHandler = if (has_websocket) Handler.WebsocketHandler else DummyWebsocketHandler;

    const RouterConfig = struct {
        middlewares: []const Middleware(H) = &.{},
    };

    return struct {
        handler: H,
        config: Config,
        arena: Allocator,
        allocator: Allocator,
        _router: Router(H, ActionArg),
        _mut: Thread.Mutex,
        _workers: []Worker,
        _cond: Thread.Condition,
        _listener: ?posix.socket_t,
        _max_request_per_connection: usize,
        _middlewares: []const Middleware(H),
        _websocket_state: websocket.server.WorkerState,
        _middleware_registry: std.SinglyLinkedList(Middleware(H)),

        const Self = @This();
        const Worker = if (blockingMode()) worker.Blocking(*Self, WebsocketHandler) else worker.NonBlocking(*Self, WebsocketHandler);

        pub fn init(allocator: Allocator, config: Config, handler: H) !Self {
            // Be mindful about where we pass this arena. Most things are able to
            // do dynamic allocation, and need to be able to free when they're
            // done with their memory. Only use this for stuff that's created on
            // startup and won't dynamically need to grow/shrink.
            const arena = try allocator.create(std.heap.ArenaAllocator);
            errdefer allocator.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const default_dispatcher = if (comptime Handler == void) defaultDispatcher else defaultDispatcherWithHandler;

            // do not pass arena.allocator to WorkerState, it needs to be able to
            // allocate and free at will.
            const ws_config = config.websocket;
            var websocket_state = try websocket.server.WorkerState.init(allocator, .{
                .max_message_size = ws_config.max_message_size,
                .buffers = .{
                    .small_size = if (has_websocket) ws_config.small_buffer_size else 0,
                    .small_pool = if (has_websocket) ws_config.small_buffer_pool else 0,
                    .large_size = if (has_websocket) ws_config.large_buffer_size else 0,
                    .large_pool = if (has_websocket) ws_config.large_buffer_pool else 0,
                },
                // disable handshake memory allocation since httpz is handling
                // the handshake request directly
                .handshake = .{
                    .count = 0,
                    .max_size = 0,
                    .max_headers = 0,
                },
                .compression = if (ws_config.compression) .{
                    .write_threshold = ws_config.compression_write_treshold,
                    .retain_write_buffer = ws_config.compression_retain_writer,
                } else null,
            });
            errdefer websocket_state.deinit();

            const workers = try arena.allocator().alloc(Worker, config.workerCount());

            return .{
                .config = config,
                .handler = handler,
                .allocator = allocator,
                .arena = arena.allocator(),
                ._mut = .{},
                ._cond = .{},
                ._workers = workers,
                ._listener = null,
                ._middlewares = &.{},
                ._middleware_registry = .{},
                ._websocket_state = websocket_state,
                ._router = try Router(H, ActionArg).init(arena.allocator(), default_dispatcher, handler),
                ._max_request_per_connection = config.timeout.request_count orelse MAX_REQUEST_COUNT,
            };
        }

        pub fn deinit(self: *Self) void {
            self._websocket_state.deinit();

            var node = self._middleware_registry.first;
            while (node) |n| {
                n.data.deinit();
                node = n.next;
            }

            const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
            arena.deinit();
            self.allocator.destroy(arena);
        }

        pub fn listen(self: *Self) !void {
            // incase "stop" is waiting
            defer self._cond.signal();
            self._mut.lock();

            const config = self.config;

            var no_delay = true;
            const address = blk: {
                if (config.unix_path) |unix_path| {
                    if (comptime std.net.has_unix_sockets == false) {
                        return error.UnixPathNotSupported;
                    }
                    no_delay = false;
                    std.fs.deleteFileAbsolute(unix_path) catch {};
                    break :blk try net.Address.initUnix(unix_path);
                } else {
                    const listen_port = config.port orelse 5882;
                    const listen_address = config.address orelse "127.0.0.1";
                    break :blk try net.Address.parseIp(listen_address, listen_port);
                }
            };

            const listener = blk: {
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
                try posix.setsockopt(listener, posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
            }

            try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            if (config.unix_path == null and self._workers.len > 1) {
                if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
                    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
                } else if (@hasDecl(posix.SO, "REUSEPORT")) {
                    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
                }
            }

            {
                const socklen = address.getOsSockLen();
                try posix.bind(listener, &address.any, socklen);
                try posix.listen(listener, 1024); // kernel backlog
            }

            self._listener = listener;

            var workers = self._workers;
            const allocator = self.allocator;

            if (comptime blockingMode()) {
                workers[0] = try worker.Blocking(*Self, WebsocketHandler).init(allocator, self, &config);
                defer workers[0].deinit();

                const thrd = try Thread.spawn(.{}, worker.Blocking(*Self, WebsocketHandler).listen, .{ &workers[0], listener });

                // incase listenInNewThread was used and is waiting for us to start
                self._cond.signal();
                self._mut.unlock();

                // This will unblock when server.stop() is called and the listening
                // socket is closed.
                thrd.join();
            } else {
                var started: usize = 0;
                defer for (0..started) |i| {
                    workers[i].deinit();
                };

                errdefer for (0..started) |i| {
                    workers[i].stop();
                };

                var ready_sem = std.Thread.Semaphore{};
                const threads = try self.arena.alloc(Thread, workers.len);
                for (0..workers.len) |i| {
                    workers[i] = try Worker.init(allocator, self, &config);
                    errdefer {
                        workers[i].stop();
                        workers[i].deinit();
                    }
                    threads[i] = try Thread.spawn(.{}, Worker.run, .{ &workers[i], listener, &ready_sem });
                    started += 1;
                }

                for (0..workers.len) |_| {
                    ready_sem.wait();
                }

                // incase listenInNewThread was used and is waiting for us to start
                self._cond.signal();
                self._mut.unlock();

                for (threads) |thrd| {
                    thrd.join();
                }
            }
        }

        pub fn listenInNewThread(self: *Self) !std.Thread {
            self._mut.lock();
            defer self._mut.unlock();
            const thrd = try std.Thread.spawn(.{}, listen, .{self});

            // we don't return until listen() signals us that the server is up
            self._cond.wait(&self._mut);

            return thrd;
        }

        pub fn stop(self: *Self) void {
            self._mut.lock();
            defer self._mut.unlock();

            for (self._workers) |*w| {
                w.stop();
            }

            if (self._listener) |l| {
                if (comptime blockingMode()) {
                    // necessary to unblock accept on linux
                    // (which might not be that necessary since, on Linux,
                    // NonBlocking should be used)
                    posix.shutdown(l, .recv) catch {};
                }
                posix.close(l);
            }
        }

        pub fn router(self: *Self, config: RouterConfig) !*Router(H, ActionArg) {
            // we store this in self for us when no route is found (these will
            // still be executed).

            const owned = try self.arena.dupe(Middleware(H), config.middlewares);
            self._middlewares = owned;

            // we store this in router to append to add/append to created routes
            self._router.middlewares = owned;

            return &self._router;
        }

        fn defaultDispatcher(action: ActionArg, req: *Request, res: *Response) !void {
            return action(req, res);
        }

        fn defaultDispatcherWithHandler(handler: H, action: ActionArg, req: *Request, res: *Response) !void {
            if (comptime std.meta.hasFn(Handler, "dispatch")) {
                return handler.dispatch(action, req, res);
            }
            return action(handler, req, res);
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
        pub fn handleRequest(self: *Self, conn: *HTTPConn, thread_buf: []u8) void {
            const aa = conn.req_arena.allocator();

            var fba = FixedBufferAllocator.init(thread_buf);
            var fb = FallbackAllocator{
                .fba = &fba,
                .fallback = aa,
                .fixed = fba.allocator(),
            };

            const allocator = fb.allocator();
            var req = Request.init(allocator, conn);
            var res = Response.init(allocator, conn);

            defer std.debug.assert(res.written == true);

            if (comptime std.meta.hasFn(Handler, "handle")) {
                if (comptime @typeInfo(@TypeOf(Handler.handle)).@"fn".return_type != void) {
                    @compileError(@typeName(Handler) ++ ".handle must return 'void'");
                }
                self.handler.handle(&req, &res);
            } else {
                const dispatchable_action = self._router.route(req.method, req.method_string, req.url.path, req.params);

                var executor = Executor{
                    .index = 0,
                    .req = &req,
                    .res = &res,
                    .handler = self.handler,
                    .middlewares = undefined,
                    .dispatchable_action = dispatchable_action,
                };

                if (dispatchable_action) |da| {
                    req.route_data = da.data;
                    executor.middlewares = da.middlewares;
                } else {
                    req.route_data = null;
                    executor.middlewares = self._middlewares;
                }

                executor.next() catch |err| {
                    if (comptime std.meta.hasFn(Handler, "uncaughtError")) {
                        self.handler.uncaughtError(&req, &res, err);
                    } else {
                        res.status = 500;
                        res.body = "Internal Server Error";
                        std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{ req.url.raw, err });
                    }
                };
            }

            if (conn.handover == .unknown) {
                // close is the default
                conn.handover = if (req.canKeepAlive() and conn.request_count < self._max_request_per_connection) .keepalive else .close;
            }

            res.write() catch {
                conn.handover = .close;
            };

            if (req.unread_body > 0 and conn.handover == .keepalive) {
                drain(&req) catch {
                    conn.handover = .close;
                };
            }
        }

        pub fn middleware(self: *Self, comptime M: type, config: M.Config) !Middleware(H) {
            const arena = self.arena;

            const node = try arena.create(std.SinglyLinkedList(Middleware(H)).Node);
            errdefer arena.destroy(node);

            const m = try arena.create(M);
            errdefer arena.destroy(m);
            switch (comptime @typeInfo(@TypeOf(M.init)).@"fn".params.len) {
                1 => m.* = try M.init(config),
                2 => m.* = try M.init(config, MiddlewareConfig{
                    .arena = arena,
                    .allocator = self.allocator,
                }),
                else => @compileError(@typeName(M) ++ ".init should accept 1 or 2 parameters"),
            }

            const iface = Middleware(H).init(m);
            node.data = iface;
            self._middleware_registry.prepend(node);

            return iface;
        }

        pub const Executor = struct {
            index: usize,
            req: *Request,
            res: *Response,
            handler: H,
            // pull this out of da since we'll access it a lot (not really, but w/e)
            middlewares: []const Middleware(H),
            dispatchable_action: ?*const DispatchableAction(H, ActionArg),

            pub fn next(self: *Executor) !void {
                const index = self.index;
                const middlewares = self.middlewares;

                if (index < middlewares.len) {
                    self.index = index + 1;
                    return middlewares[index].execute(self.req, self.res, self);
                }

                // done executing our middlewares, now we either execute the
                // dispatcher or not found.
                if (self.dispatchable_action) |da| {
                    if (comptime H == void) {
                        return da.dispatcher(da.action, self.req, self.res);
                    }
                    return da.dispatcher(da.handler, da.action, self.req, self.res);
                }

                if (comptime std.meta.hasFn(Handler, "notFound")) {
                    return self.handler.notFound(self.req, self.res);
                }
                self.res.status = 404;
                self.res.body = "Not Found";
                return;
            }
        };
    };
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

pub fn upgradeWebsocket(comptime H: type, req: *Request, res: *Response, ctx: anytype) !bool {
    const upgrade = req.header("upgrade") orelse return false;
    if (std.ascii.eqlIgnoreCase(upgrade, "websocket") == false) {
        return false;
    }

    const version = req.header("sec-websocket-version") orelse return false;
    if (std.ascii.eqlIgnoreCase(version, "13") == false) {
        return false;
    }

    // firefox will send multiple values for this header
    const connection = req.header("connection") orelse return false;
    if (std.ascii.indexOfIgnoreCase(connection, "upgrade") == null) {
        return false;
    }

    const key = req.header("sec-websocket-key") orelse return false;

    const http_conn = res.conn;
    const ws_worker: *websocket.server.Worker(H) = @ptrCast(@alignCast(http_conn.ws_worker));

    var hc = try ws_worker.createConn(http_conn.stream.handle, http_conn.address, worker.timestamp(0));
    errdefer ws_worker.cleanupConn(hc);

    hc.handler = try H.init(&hc.conn, ctx);

    var agreed_compression: ?websocket.Compression = null;
    if (ws_worker.canCompress()) {
        if (req.header("sec-websocket-extensions")) |ext| {
            if (try websocket.Handshake.parseExtension(ext)) |request_compression| {
                agreed_compression = .{
                    .client_no_context_takeover = request_compression.client_no_context_takeover,
                    .server_no_context_takeover = request_compression.server_no_context_takeover,
                };
            }
        }
    }

    var reply_buf: [512]u8 = undefined;
    try http_conn.stream.writeAll(websocket.Handshake.createReply(key, agreed_compression, &reply_buf));
    if (comptime std.meta.hasFn(H, "afterInit")) {
        const params = @typeInfo(@TypeOf(H.afterInit)).@"fn".params;
        try if (comptime params.len == 1) hc.handler.?.afterInit() else hc.handler.?.afterInit(ctx);
    }
    try ws_worker.setupConnection(hc, agreed_compression);
    res.written = true;
    http_conn.handover = .{ .websocket = hc };
    return true;
}

// std.heap.StackFallbackAllocator is very specific. It's really _stack_ as it
// requires a comptime size. Also, it uses non-public calls from the FixedBufferAllocator.
// There should be a more generic FallbackAllocator that just takes 2 allocators...
// which is what this is.
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
                .remap = remap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FallbackAllocator = @ptrCast(@alignCast(ctx));
        return self.fixed.rawAlloc(len, alignment, ra) orelse self.fallback.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *FallbackAllocator = @ptrCast(@alignCast(ctx));
        if (self.fba.ownsPtr(buf.ptr)) {
            if (self.fixed.rawResize(buf, alignment, new_len, ra)) {
                return true;
            }
        }
        return self.fallback.rawResize(buf, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = ra;
        // hack.
        // Always noop since, in our specific usage, we know fallback is an arena.
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (resize(ctx, memory, alignment, new_len, ret_addr)) {
            return memory.ptr;
        }
        return null;
    }
};

// Called when we have unread bytes on the request and want to keepalive the
// connection. Only happens when lazy_read_size is configured and the client
// didn't read the [whole] body
// There should already be a receive timeout on the socket since the only
// way for this to be
fn drain(req: *Request) !void {
    var r = try req.reader(2000);
    var buf: [4096]u8 = undefined;
    while (true) {
        if (try r.read(&buf) == 0) {
            return;
        }
    }
}

const t = @import("t.zig");
var global_test_allocator = std.heap.GeneralPurposeAllocator(.{}){};

var test_handler_dispatch = TestHandlerDispatch{ .state = 10 };
var test_handler_disaptch_context = TestHandlerDispatchContext{ .state = 20 };
var test_handler_default_dispatch1 = TestHandlerDefaultDispatch{ .state = 3 };
var test_handler_default_dispatch2 = TestHandlerDefaultDispatch{ .state = 99 };
var test_handler_default_dispatch3 = TestHandlerDefaultDispatch{ .state = 20 };

var default_server: Server(void) = undefined;
var dispatch_default_server: Server(*TestHandlerDefaultDispatch) = undefined;
var dispatch_server: Server(*TestHandlerDispatch) = undefined;
var dispatch_action_context_server: Server(*TestHandlerDispatchContext) = undefined;
var reuse_server: Server(void) = undefined;
var handle_server: Server(TestHandlerHandle) = undefined;
var websocket_server: Server(TestWebsocketHandler) = undefined;

var test_server_threads: [7]Thread = undefined;

test "tests:beforeAll" {
    // this will leak since the server will run until the process exits. If we use
    // our testing allocator, it'll report the leak.
    const ga = global_test_allocator.allocator();

    {
        default_server = try Server(void).init(ga, .{ .port = 5992, .request = .{
            .lazy_read_size = 4_096,
            .max_body_size = 1_048_576,
        } }, {});

        // only need to do this because we're using listenInNewThread instead
        // of blocking here. So the array to hold the middleware needs to outlive
        // this function.
        var cors = try default_server.arena.alloc(Middleware(void), 1);
        cors[0] = try default_server.middleware(middleware.Cors, .{
            .max_age = "300",
            .methods = "GET,POST",
            .origin = "httpz.local",
            .headers = "content-type",
        });

        var middlewares = try default_server.arena.alloc(Middleware(void), 2);
        middlewares[0] = try default_server.middleware(TestMiddleware, .{ .id = 100 });
        middlewares[1] = cors[0];

        var router = try default_server.router(.{});
        // router.get("/test/ws", testWS);
        router.get("/fail", TestDummyHandler.fail, .{});
        router.get("/test/json", TestDummyHandler.jsonRes, .{});
        router.get("/test/method", TestDummyHandler.method, .{});
        router.put("/test/method", TestDummyHandler.method, .{});
        router.method("TEA", "/test/method", TestDummyHandler.method, .{});
        router.method("PING", "/test/method", TestDummyHandler.method, .{});
        router.get("/test/query", TestDummyHandler.reqQuery, .{});
        router.get("/test/stream", TestDummyHandler.eventStream, .{});
        router.get("/test/streamsync", TestDummyHandler.eventStreamSync, .{});
        router.get("/test/req_reader", TestDummyHandler.reqReader, .{});
        router.get("/test/chunked", TestDummyHandler.chunked, .{});
        router.get("/test/route_data", TestDummyHandler.routeData, .{ .data = &TestDummyHandler.RouteData{ .power = 12345 } });
        router.all("/test/cors", TestDummyHandler.jsonRes, .{ .middlewares = cors });
        router.all("/test/middlewares", TestDummyHandler.middlewares, .{ .middlewares = middlewares });
        router.all("/test/dispatcher", TestDummyHandler.dispatchedAction, .{ .dispatcher = TestDummyHandler.routeSpecificDispacthcer });
        test_server_threads[0] = try default_server.listenInNewThread();
    }

    {
        dispatch_default_server = try Server(*TestHandlerDefaultDispatch).init(ga, .{ .port = 5993 }, &test_handler_default_dispatch1);
        var router = try dispatch_default_server.router(.{});
        router.get("/", TestHandlerDefaultDispatch.echo, .{});
        router.get("/write/*", TestHandlerDefaultDispatch.echoWrite, .{});
        router.get("/fail", TestHandlerDefaultDispatch.fail, .{});
        router.post("/login", TestHandlerDefaultDispatch.echo, .{});
        router.get("/test/body/cl", TestHandlerDefaultDispatch.clBody, .{});
        router.get("/test/headers", TestHandlerDefaultDispatch.headers, .{});
        router.all("/api/:version/users/:UserId", TestHandlerDefaultDispatch.params, .{});

        var admin_routes = router.group("/admin/", .{ .dispatcher = TestHandlerDefaultDispatch.dispatch2, .handler = &test_handler_default_dispatch2 });
        admin_routes.get("/users", TestHandlerDefaultDispatch.echo, .{});
        admin_routes.put("/users/:id", TestHandlerDefaultDispatch.echo, .{});

        var debug_routes = router.group("/debug", .{ .dispatcher = TestHandlerDefaultDispatch.dispatch3, .handler = &test_handler_default_dispatch3 });
        debug_routes.head("/ping", TestHandlerDefaultDispatch.echo, .{});
        debug_routes.options("/stats", TestHandlerDefaultDispatch.echo, .{});

        test_server_threads[1] = try dispatch_default_server.listenInNewThread();
    }

    {
        dispatch_server = try Server(*TestHandlerDispatch).init(ga, .{ .port = 5994 }, &test_handler_dispatch);
        var router = try dispatch_server.router(.{});
        router.get("/", TestHandlerDispatch.root, .{});
        test_server_threads[2] = try dispatch_server.listenInNewThread();
    }

    {
        dispatch_action_context_server = try Server(*TestHandlerDispatchContext).init(ga, .{ .port = 5995 }, &test_handler_disaptch_context);
        var router = try dispatch_action_context_server.router(.{});
        router.get("/", TestHandlerDispatchContext.root, .{});
        test_server_threads[3] = try dispatch_action_context_server.listenInNewThread();
    }

    {
        // with only 1 worker, and a min/max conn of 1, each request should
        // hit our reset path.
        reuse_server = try Server(void).init(ga, .{ .port = 5996, .workers = .{ .count = 1, .min_conn = 1, .max_conn = 1 } }, {});
        var router = try reuse_server.router(.{});
        router.get("/test/writer", TestDummyHandler.reuseWriter, .{});
        test_server_threads[4] = try reuse_server.listenInNewThread();
    }

    {
        handle_server = try Server(TestHandlerHandle).init(ga, .{ .port = 5997 }, TestHandlerHandle{});
        test_server_threads[5] = try handle_server.listenInNewThread();
    }

    {
        websocket_server = try Server(TestWebsocketHandler).init(ga, .{ .port = 5998 }, TestWebsocketHandler{});
        var router = try websocket_server.router(.{});
        router.get("/ws", TestWebsocketHandler.upgrade, .{});
        test_server_threads[6] = try websocket_server.listenInNewThread();
    }

    std.testing.refAllDecls(@This());
}

test "tests:afterAll" {
    default_server.stop();
    dispatch_default_server.stop();
    dispatch_server.stop();
    dispatch_action_context_server.stop();
    reuse_server.stop();
    handle_server.stop();
    websocket_server.stop();

    for (test_server_threads) |thread| {
        thread.join();
    }

    default_server.deinit();
    dispatch_default_server.deinit();
    dispatch_server.deinit();
    dispatch_action_context_server.deinit();
    reuse_server.deinit();
    handle_server.deinit();
    websocket_server.deinit();

    try t.expectEqual(false, global_test_allocator.detectLeaks());
}

test "httpz: quick shutdown" {
    var server = try Server(void).init(t.allocator, .{ .port = 6992 }, {});
    const thrd = try server.listenInNewThread();
    server.stop();
    thrd.join();
    server.deinit();
}

test "httpz: invalid request" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("TEA HTTP/1.1\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "httpz: invalid request path" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("TEA /hello\rn\nWorld:test HTTP/1.1\r\n\r\n");

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

test "httpz: invalid content length value (1)" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nContent-Length: HaHA\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "httpz: invalid content length value (2)" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nContent-Length: 1.0\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nContent-Length: 15\r\n\r\nInvalid Request", testReadAll(stream, &buf));
}

test "httpz: body too big" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("POST / HTTP/1.1\r\nContent-Length: 999999999999999999\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 413 \r\nConnection: Close\r\nContent-Length: 23\r\n\r\nRequest body is too big", testReadAll(stream, &buf));
}

test "httpz: overflow content length" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nContent-Length: 999999999999999999999999999\r\n\r\n");

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
    try t.expectString("HTTP/1.1 404 \r\nstate: 3\r\nContent-Length: 10\r\n\r\nwhere lah?", testReadAll(stream, &buf));
}

test "httpz: unhandled exception" {
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /fail HTTP/1.1\r\n\r\n");

    var buf: [150]u8 = undefined;
    try t.expectString("HTTP/1.1 500 \r\nContent-Length: 21\r\n\r\nInternal Server Error", testReadAll(stream, &buf));
}

test "httpz: unhandled exception with custom error handler" {
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /fail HTTP/1.1\r\n\r\n");

    var buf: [150]u8 = undefined;
    try t.expectString("HTTP/1.1 500 \r\nstate: 3\r\nerr: TestUnhandledError\r\nContent-Length: 29\r\n\r\n#/why/arent/tags/hierarchical", testReadAll(stream, &buf));
}

test "httpz: custom methods" {
    const stream = testStream(5992);
    defer stream.close();

    {
        try stream.writeAll("GET /test/method HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();
        try res.expectJson(.{ .method = "GET", .string = "" });
    }

    {
        try stream.writeAll("PUT /test/method HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();
        try res.expectJson(.{ .method = "PUT", .string = "" });
    }

    {
        try stream.writeAll("TEA /test/method HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();
        try res.expectJson(.{ .method = "OTHER", .string = "TEA" });
    }

    {
        try stream.writeAll("PING /test/method HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();
        try res.expectJson(.{ .method = "OTHER", .string = "PING" });
    }

    {
        try stream.writeAll("TEA /test/other HTTP/1.1\r\n\r\n");
        var buf: [100]u8 = undefined;
        try t.expectString("HTTP/1.1 404 \r\nContent-Length: 9\r\n\r\nNot Found", testReadAll(stream, &buf));
    }
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
    try t.expectString("HTTP/1.1 200 \r\nstate: 3\r\nEcho: Header-Value\r\nother: test-value\r\nContent-Length: 0\r\n\r\n", testReadAll(stream, &buf));
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

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 201 \r\nContent-Type: application/json; charset=UTF-8\r\nContent-Length: 26\r\n\r\n{\"over\":9000,\"teg\":\"soup\"}", testReadAll(stream, &buf));
}

test "httpz: query" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/query?fav=keemun%20te%61%21 HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 11\r\n\r\nkeemun tea!", testReadAll(stream, &buf));
}

test "httpz: chunked" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/chunked HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [1000]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nOver: 9000!\r\nTransfer-Encoding: chunked\r\n\r\n7\r\nChunk 1\r\n11\r\nand another chunk\r\n0\r\n\r\n", testReadAll(stream, &buf));
}

test "httpz: route-specific dispatcher" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("HEAD /test/dispatcher HTTP/1.1\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\ndispatcher: test-dispatcher-1\r\nContent-Length: 6\r\n\r\naction", testReadAll(stream, &buf));
}

test "httpz: middlewares" {
    const stream = testStream(5992);
    defer stream.close();

    {
        try stream.writeAll("GET /test/middlewares HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .v1 = "tm1-100", .v2 = "tm2-100" });
        try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
    }
}

test "httpz: CORS" {
    const stream = testStream(5992);
    defer stream.close();

    {
        try stream.writeAll("GET /echo HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();
        try t.expectEqual(null, res.headers.get("Access-Control-Max-Age"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Methods"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Headers"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Origin"));
    }

    {
        // cors endpoint but not cors options
        try stream.writeAll("OPTIONS /test/cors HTTP/1.1\r\nSec-Fetch-Mode: navigate\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try t.expectEqual(null, res.headers.get("Access-Control-Max-Age"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Methods"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Headers"));
        try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
    }

    {
        // cors request
        try stream.writeAll("OPTIONS /test/cors HTTP/1.1\r\nSec-Fetch-Mode: cors\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try t.expectString("300", res.headers.get("Access-Control-Max-Age").?);
        try t.expectString("GET,POST", res.headers.get("Access-Control-Allow-Methods").?);
        try t.expectString("content-type", res.headers.get("Access-Control-Allow-Headers").?);
        try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
    }

    {
        // cors request, non-options
        try stream.writeAll("GET /test/cors HTTP/1.1\r\nSec-Fetch-Mode: cors\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try t.expectEqual(null, res.headers.get("Access-Control-Max-Age"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Methods"));
        try t.expectEqual(null, res.headers.get("Access-Control-Allow-Headers"));
        try t.expectString("httpz.local", res.headers.get("Access-Control-Allow-Origin").?);
    }
}

test "httpz: router groups" {
    const stream = testStream(5993);
    defer stream.close();

    {
        try stream.writeAll("GET / HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 3, .method = "GET", .path = "/" });
        try t.expectEqual(true, res.headers.get("dispatcher") == null);
    }

    {
        try stream.writeAll("GET /admin/users HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 99, .method = "GET", .path = "/admin/users" });
        try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("PUT /admin/users/:id HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 99, .method = "PUT", .path = "/admin/users/:id" });
        try t.expectString("test-dispatcher-2", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("HEAD /debug/ping HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 20, .method = "HEAD", .path = "/debug/ping" });
        try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("OPTIONS /debug/stats HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 20, .method = "OPTIONS", .path = "/debug/stats" });
        try t.expectString("test-dispatcher-3", res.headers.get("dispatcher").?);
    }

    {
        try stream.writeAll("POST /login HTTP/1.1\r\n\r\n");
        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .state = 3, .method = "POST", .path = "/login" });
        try t.expectEqual(true, res.headers.get("dispatcher") == null);
    }
}

test "httpz: event stream" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/stream HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();

    try t.expectEqual(818, res.status);
    try t.expectEqual(true, res.headers.get("Content-Length") == null);
    try t.expectString("text/event-stream; charset=UTF-8", res.headers.get("Content-Type").?);
    try t.expectString("no-cache", res.headers.get("Cache-Control").?);
    try t.expectString("keep-alive", res.headers.get("Connection").?);
    try t.expectString("helloa message", res.body);
}

test "httpz: event stream sync" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/streamsync HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();

    try t.expectEqual(818, res.status);
    try t.expectEqual(true, res.headers.get("Content-Length") == null);
    try t.expectString("text/event-stream; charset=UTF-8", res.headers.get("Content-Type").?);
    try t.expectString("no-cache", res.headers.get("Cache-Control").?);
    try t.expectString("keep-alive", res.headers.get("Connection").?);
    try t.expectString("helloa sync message", res.body);
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

test "httpz: route data" {
    const stream = testStream(5992);
    defer stream.close();
    try stream.writeAll("GET /test/route_data HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();
    try res.expectJson(.{ .power = 12345 });
}

test "httpz: keepalive with explicit write" {
    const stream = testStream(5993);
    defer stream.close();
    try stream.writeAll("GET /write/9001 HTTP/1.1\r\n\r\n");

    var buf: [1000]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 47\r\n\r\n{\"state\":3,\"method\":\"GET\",\"path\":\"/write/9001\"}", testReadAll(stream, &buf));

    try stream.writeAll("GET /write/123 HTTP/1.1\r\n\r\n");
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 46\r\n\r\n{\"state\":3,\"method\":\"GET\",\"path\":\"/write/123\"}", testReadAll(stream, &buf));
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

test "httpz: writer re-use" {
    defer t.reset();

    const stream = testStream(5996);
    defer stream.close();

    var expected: [10]TestUser = undefined;

    var buf: [100]u8 = undefined;
    for (0..10) |i| {
        expected[i] = .{
            .id = try std.fmt.allocPrint(t.arena.allocator(), "id-{d}", .{i}),
            .power = i,
        };
        try stream.writeAll(try std.fmt.bufPrint(&buf, "GET /test/writer?count={d} HTTP/1.1\r\nContent-Length: 0\r\n\r\n", .{i + 1}));

        var res = testReadParsed(stream);
        defer res.deinit();

        try res.expectJson(.{ .data = expected[0 .. i + 1] });
    }
}

test "httpz: custom dispatch without action context" {
    const stream = testStream(5994);
    defer stream.close();
    try stream.writeAll("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Type: application/json; charset=UTF-8\r\ndstate: 10\r\ndispatch: TestHandlerDispatch\r\nContent-Length: 12\r\n\r\n{\"state\":10}", testReadAll(stream, &buf));
}

test "httpz: custom dispatch with action context" {
    const stream = testStream(5995);
    defer stream.close();
    try stream.writeAll("GET /?name=teg HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [200]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Type: application/json; charset=UTF-8\r\ndstate: 20\r\ndispatch: TestHandlerDispatchContext\r\nContent-Length: 12\r\n\r\n{\"other\":30}", testReadAll(stream, &buf));
}

test "httpz: custom handle" {
    const stream = testStream(5997);
    defer stream.close();
    try stream.writeAll("GET /whatever?name=teg HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var buf: [100]u8 = undefined;
    try t.expectString("HTTP/1.1 200 \r\nContent-Length: 9\r\n\r\nhello teg", testReadAll(stream, &buf));
}

test "httpz: request body reader" {
    {
        // no body
        const stream = testStream(5992);
        defer stream.close();
        try stream.writeAll("GET /test/req_reader HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

        var res = testReadParsed(stream);
        defer res.deinit();
        try res.expectJson(.{ .length = 0 });
    }

    {
        // small body
        const stream = testStream(5992);
        defer stream.close();
        try stream.writeAll("GET /test/req_reader HTTP/1.1\r\nContent-Length: 4\r\n\r\n123z");

        var res = testReadParsed(stream);
        defer res.deinit();
        try res.expectJson(.{ .length = 4 });
    }

    var r = t.getRandom();
    const random = r.random();

    // a bit of fuzzing
    for (0..10) |_| {
        const stream = testStream(5992);
        defer stream.close();
        var req: []const u8 = "GET /test/req_reader HTTP/1.1\r\nContent-Length: 20000\r\n\r\n" ++ ("a" ** 20_000);
        while (req.len > 0) {
            const len = random.uintAtMost(usize, req.len - 1) + 1;
            const n = stream.write(req[0..len]) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            std.time.sleep(std.time.ns_per_ms * 2);
            req = req[n..];
        }

        var res = testReadParsed(stream);
        defer res.deinit();
        try res.expectJson(.{ .length = 20_000 });
    }
}

test "websocket: invalid request" {
    const stream = testStream(5998);
    defer stream.close();
    try stream.writeAll("GET /ws HTTP/1.1\r\nContent-Length: 0\r\n\r\n");

    var res = testReadParsed(stream);
    defer res.deinit();
    try t.expectString("invalid websocket", res.body);
}

test "websocket: upgrade" {
    const stream = testStream(5998);
    defer stream.close();
    try stream.writeAll("GET /ws HTTP/1.1\r\nContent-Length: 0\r\n");
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
    try stream.writeAll(&websocket.frameText("close"));

    var pos: usize = 0;
    var buf: [100]u8 = undefined;
    var wait_count: usize = 0;
    while (pos < 16) {
        const n = stream.read(buf[pos..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (wait_count == 100) {
                    break;
                }
                wait_count += 1;
                std.time.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) {
            break;
        }
        pos += n;
    }
    try t.expectEqual(16, pos);
    try t.expectEqual(129, buf[0]);
    try t.expectEqual(10, buf[1]);
    try t.expectString("over 9000!", buf[2..12]);
    try t.expectString(&.{ 136, 2, 3, 232 }, buf[12..16]);
}

test "ContentType: forX" {
    inline for (@typeInfo(ContentType).@"enum".fields) |field| {
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

fn testStream(port: u16) std.net.Stream {
    const timeout = std.mem.toBytes(posix.timeval{
        .sec = 0,
        .usec = 20_000,
    });

    const address = std.net.Address.parseIp("127.0.0.1", port) catch unreachable;
    const stream = std.net.tcpConnectToAddress(address) catch unreachable;
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout) catch unreachable;
    posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch unreachable;
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
            error.ConnectionResetByPeer => return buf[0..pos],
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

const TestUser = struct {
    id: []const u8,
    power: usize,
};

// simulates having a void handler, but keeps the test actions organized within
// this namespace.
const TestDummyHandler = struct {
    const RouteData = struct {
        power: usize,
    };

    fn fail(_: *Request, _: *Response) !void {
        return error.Failure;
    }

    fn reqQuery(req: *Request, res: *Response) !void {
        res.status = 200;
        const query = try req.query();
        res.body = query.get("fav").?;
    }

    fn method(req: *Request, res: *Response) !void {
        try res.json(.{ .method = req.method, .string = req.method_string }, .{});
    }

    fn chunked(_: *Request, res: *Response) !void {
        res.header("Over", "9000!");
        res.status = 200;
        try res.chunk("Chunk 1");
        try res.chunk("and another chunk");
    }

    fn jsonRes(_: *Request, res: *Response) !void {
        res.setStatus(.created);
        try res.json(.{ .over = 9000, .teg = "soup" }, .{});
    }

    fn routeData(req: *Request, res: *Response) !void {
        const rd: *const RouteData = @ptrCast(@alignCast(req.route_data.?));
        try res.json(.{ .power = rd.power }, .{});
    }

    fn eventStream(_: *Request, res: *Response) !void {
        res.status = 818;
        try res.startEventStream(StreamContext{ .data = "hello" }, StreamContext.handle);
    }

    fn eventStreamSync(_: *Request, res: *Response) !void {
        res.status = 818;
        const stream = try res.startEventStreamSync();
        const w = stream.writer();
        w.writeAll("hello") catch unreachable;
        w.writeAll("a sync message") catch unreachable;
    }

    fn reqReader(req: *Request, res: *Response) !void {
        var reader = try req.reader(2000);

        var l: usize = 0;
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) {
                break;
            }
            if (req.body_len > 10 and std.mem.indexOfNonePos(u8, buf[0..n], 0, "a") != null) {
                return error.InvalidData;
            }
            l += n;
        }
        return res.json(.{ .length = l }, .{});
    }

    const StreamContext = struct {
        data: []const u8,

        fn handle(self: StreamContext, stream: std.net.Stream) void {
            stream.writeAll(self.data) catch unreachable;
            stream.writeAll("a message") catch unreachable;
        }
    };

    fn routeSpecificDispacthcer(action: Action(void), req: *Request, res: *Response) !void {
        res.header("dispatcher", "test-dispatcher-1");
        return action(req, res);
    }

    fn dispatchedAction(_: *Request, res: *Response) !void {
        return res.directWriter().writeAll("action");
    }

    fn middlewares(req: *Request, res: *Response) !void {
        return res.json(.{
            .v1 = TestMiddleware.value1(req),
            .v2 = TestMiddleware.value2(req),
        }, .{});
    }

    // called by the re-use server, but put here because, like the default server
    // this is a handler-less server
    fn reuseWriter(req: *Request, res: *Response) !void {
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
        return res.json(.{ .data = data }, .{});
    }
};

const TestHandlerDefaultDispatch = struct {
    state: usize,

    fn dispatch2(h: *TestHandlerDefaultDispatch, action: Action(*TestHandlerDefaultDispatch), req: *Request, res: *Response) !void {
        res.header("dispatcher", "test-dispatcher-2");
        return action(h, req, res);
    }

    fn dispatch3(h: *TestHandlerDefaultDispatch, action: Action(*TestHandlerDefaultDispatch), req: *Request, res: *Response) !void {
        res.header("dispatcher", "test-dispatcher-3");
        return action(h, req, res);
    }

    fn echo(h: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        return res.json(.{
            .state = h.state,
            .method = @tagName(req.method),
            .path = req.url.path,
        }, .{});
    }

    fn echoWrite(h: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        var arr = std.ArrayList(u8).init(res.arena);
        try std.json.stringify(.{
            .state = h.state,
            .method = @tagName(req.method),
            .path = req.url.path,
        }, .{}, arr.writer());

        res.body = arr.items;
        return res.write();
    }

    fn params(_: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        const args = .{ req.param("version").?, req.param("UserId").? };
        res.body = try std.fmt.allocPrint(req.arena, "version={s},user={s}", args);
    }

    fn headers(h: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        res.header("state", try std.fmt.allocPrint(res.arena, "{d}", .{h.state}));
        res.header("Echo", req.header("header-name").?);
        res.header("other", "test-value");
    }

    fn clBody(_: *TestHandlerDefaultDispatch, req: *Request, res: *Response) !void {
        res.header("Echo-Body", req.body().?);
    }

    fn fail(_: *TestHandlerDefaultDispatch, _: *Request, _: *Response) !void {
        return error.TestUnhandledError;
    }

    pub fn notFound(h: *TestHandlerDefaultDispatch, _: *Request, res: *Response) !void {
        res.status = 404;
        res.header("state", try std.fmt.allocPrint(res.arena, "{d}", .{h.state}));
        res.body = "where lah?";
    }

    pub fn uncaughtError(h: *TestHandlerDefaultDispatch, _: *Request, res: *Response, err: anyerror) void {
        res.status = 500;
        res.header("state", std.fmt.allocPrint(res.arena, "{d}", .{h.state}) catch unreachable);
        res.header("err", @errorName(err));
        res.body = "#/why/arent/tags/hierarchical";
    }
};

const TestHandlerDispatch = struct {
    state: usize,

    pub fn dispatch(self: *TestHandlerDispatch, action: Action(*TestHandlerDispatch), req: *Request, res: *Response) !void {
        res.header("dstate", try std.fmt.allocPrint(res.arena, "{d}", .{self.state}));
        res.header("dispatch", "TestHandlerDispatch");
        return action(self, req, res);
    }

    fn root(h: *TestHandlerDispatch, _: *Request, res: *Response) !void {
        return res.json(.{ .state = h.state }, .{});
    }
};

const TestHandlerDispatchContext = struct {
    state: usize,

    const ActionContext = struct {
        other: usize,
    };

    pub fn dispatch(self: *TestHandlerDispatchContext, action: Action(*ActionContext), req: *Request, res: *Response) !void {
        res.header("dstate", try std.fmt.allocPrint(res.arena, "{d}", .{self.state}));
        res.header("dispatch", "TestHandlerDispatchContext");
        var action_context = ActionContext{ .other = self.state + 10 };
        return action(&action_context, req, res);
    }

    pub fn root(a: *const ActionContext, _: *Request, res: *Response) !void {
        return res.json(.{ .other = a.other }, .{});
    }
};

const TestHandlerHandle = struct {
    pub fn handle(_: TestHandlerHandle, req: *Request, res: *Response) void {
        const query = req.query() catch unreachable;
        std.fmt.format(res.writer(), "hello {s}", .{query.get("name") orelse "world"}) catch unreachable;
    }
};

const TestWebsocketHandler = struct {
    pub const WebsocketHandler = struct {
        ctx: u32,
        conn: *websocket.Conn,

        pub fn init(conn: *websocket.Conn, ctx: u32) !WebsocketHandler {
            return .{
                .ctx = ctx,
                .conn = conn,
            };
        }

        pub fn afterInit(self: *WebsocketHandler, ctx: u32) !void {
            try t.expectEqual(self.ctx, ctx);
        }

        pub fn clientMessage(self: *WebsocketHandler, data: []const u8) !void {
            if (std.mem.eql(u8, data, "close")) {
                self.conn.close(.{}) catch {};
                return;
            }
            try self.conn.write(data);
        }
    };

    pub fn upgrade(_: TestWebsocketHandler, req: *Request, res: *Response) !void {
        if (try upgradeWebsocket(WebsocketHandler, req, res, 9001) == false) {
            res.status = 500;
            res.body = "invalid websocket";
        }
    }
};

const TestMiddleware = struct {
    const Config = struct {
        id: i32,
    };

    allocator: Allocator,
    v1: []const u8,
    v2: []const u8,

    fn init(config: TestMiddleware.Config, mc: MiddlewareConfig) !TestMiddleware {
        return .{
            .allocator = mc.allocator,
            .v1 = try std.fmt.allocPrint(mc.arena, "tm1-{d}", .{config.id}),
            .v2 = try std.fmt.allocPrint(mc.allocator, "tm2-{d}", .{config.id}),
        };
    }

    pub fn deinit(self: *const TestMiddleware) void {
        self.allocator.free(self.v2);
    }

    fn value1(req: *const Request) []const u8 {
        const v: [*]u8 = @ptrCast(req.middlewares.get("text_middleware_1").?);
        return v[0..7];
    }

    fn value2(req: *const Request) []const u8 {
        const v: [*]u8 = @ptrCast(req.middlewares.get("text_middleware_2").?);
        return v[0..7];
    }

    fn execute(self: *const TestMiddleware, req: *Request, _: *Response, executor: anytype) !void {
        try req.middlewares.put("text_middleware_1", (try req.arena.dupe(u8, self.v1)).ptr);
        try req.middlewares.put("text_middleware_2", (try req.arena.dupe(u8, self.v2)).ptr);
        return executor.next();
    }
};
