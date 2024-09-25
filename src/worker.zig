const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz.zig");
const metrics = @import("metrics.zig");
const ws = @import("websocket").server;

const Config = httpz.Config;
const Request = httpz.Request;
const Response = httpz.Response;

const BufferPool = @import("buffer.zig").Pool;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const net = std.net;
const Stream = net.Stream;
const NetConn = net.StreamServer.Connection;

const posix = std.posix;
const log = std.log.scoped(.httpz);

const MAX_TIMEOUT = 2_147_483_647;

const _Loop_type = enum {
    kqueue,
    iouring,
    none,
};

pub const LoopType: _Loop_type = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => .kqueue,
    .linux => .iouring,
    else => .none,
};

// This is our Blocking worker. It's very different than NonBlocking and much
// simpler. (WSH is our websocket handler, and can be void)
pub fn Blocking(comptime S: type, comptime WSH: type) type {
    return struct {
        server: S,
        mut: Thread.Mutex,
        config: *const Config,
        allocator: Allocator,
        buffer_pool: *BufferPool,
        http_conn_pool: HTTPConnPool,
        websocket: *ws.Worker(WSH),
        timeout_request: ?Timeout,
        timeout_keepalive: ?Timeout,
        timeout_write_error: Timeout,
        retain_allocated_bytes_keepalive: usize,
        connections: List(ConnNode),
        conn_node_pool: std.heap.MemoryPool(ConnNode),

        const ConnNode = struct {
            next: ?*ConnNode,
            prev: ?*ConnNode,
            socket: posix.fd_t,
        };

        const Timeout = struct {
            sec: u32,
            timeval: [@sizeOf(std.posix.timeval)]u8,

            // if sec is null, it means we want to cancel the timeout.
            fn init(sec: ?u32) Timeout {
                return .{
                    .sec = if (sec) |s| s else MAX_TIMEOUT,
                    .timeval = std.mem.toBytes(std.posix.timeval{ .sec = @intCast(sec orelse 0), .usec = 0 }),
                };
            }
        };

        const Self = @This();

        pub fn init(allocator: Allocator, server: S, config: *const Config) !Self {
            const buffer_pool = try initializeBufferPool(allocator, config);
            errdefer allocator.destroy(buffer_pool);

            errdefer buffer_pool.deinit();

            var timeout_request: ?Timeout = null;
            if (config.timeout.request) |sec| {
                timeout_request = Timeout.init(sec);
            } else if (config.timeout.keepalive != null) {
                // We have to set this up, so that when we transition from
                // keepalive state to a request parsing state, we remove the timeout
                timeout_request = Timeout.init(0);
            }

            var timeout_keepalive: ?Timeout = null;
            if (config.timeout.keepalive) |sec| {
                timeout_keepalive = Timeout.init(sec);
            } else if (timeout_request != null) {
                // We have to set this up, so that when we transition from
                // request processing state to a kepealive state, we remove the timeout
                timeout_keepalive = Timeout.init(0);
            }

            const websocket = try allocator.create(ws.Worker(WSH));
            errdefer allocator.destroy(websocket);
            websocket.* = try ws.Worker(WSH).init(allocator, &server._websocket_state);
            errdefer websocket.deinit();

            const http_conn_pool = try HTTPConnPool.init(allocator, buffer_pool, websocket, config);
            errdefer http_conn_pool.deinit();

            const retain_allocated_bytes_keepalive = config.workers.retain_allocated_bytes orelse 8192;

            return .{
                .mut = .{},
                .server = server,
                .config = config,
                .connections = .{},
                .allocator = allocator,
                .websocket = websocket,
                .buffer_pool = buffer_pool,
                .http_conn_pool = http_conn_pool,
                .timeout_request = timeout_request,
                .timeout_keepalive = timeout_keepalive,
                .timeout_write_error = Timeout.init(5),
                .conn_node_pool = std.heap.MemoryPool(ConnNode).init(allocator),
                .retain_allocated_bytes_keepalive = retain_allocated_bytes_keepalive,
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;

            self.websocket.deinit();
            allocator.destroy(self.websocket);

            self.http_conn_pool.deinit();

            self.buffer_pool.deinit();
            allocator.destroy(self.buffer_pool);

            self.conn_node_pool.deinit();
        }

        pub fn listen(self: *Self, listener: posix.socket_t) void {
            var server = self.server;
            var thread_pool = &server._thread_pool;
            while (true) {
                var address: net.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(net.Address);
                const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
                    if (err == error.ConnectionAborted or err == error.SocketNotListening) {
                        self.websocket.shutdown();
                        break;
                    }
                    log.err("Failed to accept socket: {}", .{err});
                    continue;
                };
                metrics.connection();
                // calls handleConnection through the server's thread_pool
                thread_pool.spawn(.{ self, socket, address });
                thread_pool.flush(1);
            }

            {
                self.mut.lock();
                defer self.mut.unlock();
                var node = self.connections.head;
                while (node) |n| {
                    node = n.next;
                    posix.close(n.socket);
                }
            }
            thread_pool.stop();
        }

        // Called in a worker thread. `thread_buf` is a thread-specific buffer that
        // we are free to use as needed.
        pub fn handleConnection(self: *Self, socket: posix.socket_t, address: net.Address, thread_buf: []u8) void {
            const connection_node = blk: {
                self.mut.lock();
                defer self.mut.unlock();
                const node = self.conn_node_pool.create() catch |err| {
                    log.err("Failed to initialize connection node: {}", .{err});
                    return;
                };
                node.* = .{
                    .next = null,
                    .prev = null,
                    .socket = socket,
                };
                self.connections.insert(node);
                break :blk node;
            };

            defer {
                self.mut.lock();
                defer self.mut.unlock();
                self.connections.remove(connection_node);
                self.conn_node_pool.destroy(connection_node);
            }

            var conn = self.http_conn_pool.acquire() catch |err| {
                log.err("Failed to initialize connection: {}", .{err});
                return;
            };

            conn.stream = .{ .handle = socket };
            conn.address = address;

            var is_keepalive = false;
            while (true) {
                switch (self.handleRequest(conn, is_keepalive, thread_buf) catch .close) {
                    .keepalive => {
                        is_keepalive = true;
                        conn.keepalive(self.retain_allocated_bytes_keepalive);
                    },
                    .close, .unknown => {
                        posix.close(socket);
                        self.http_conn_pool.release(conn);
                        return;
                    },
                    .websocket => |ptr| {
                        const hc: *ws.HandlerConn(WSH) = @ptrCast(@alignCast(ptr));
                        self.http_conn_pool.release(conn);
                        // blocking read loop
                        // will close the connection
                        self.handleWebSocket(hc) catch |err| {
                            log.err("({} websocket connection error: {}", .{ address, err });
                        };
                        return;
                    },
                    .disown => {
                        self.http_conn_pool.release(conn);
                        return;
                    },
                    .need_data => unreachable,
                }
            }
        }

        fn handleRequest(self: *const Self, conn: *HTTPConn, is_keepalive: bool, thread_buf: []u8) !HTTPConn.Handover {
            const stream = conn.stream;
            const timeout: ?Timeout = if (is_keepalive) self.timeout_keepalive else self.timeout_request;

            var deadline: ?i64 = null;

            if (timeout) |to| {
                if (is_keepalive == false) {
                    deadline = timestamp() + to.sec;
                }
                try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &to.timeval);
            }

            var is_first = true;
            var req_state = &conn.req_state;
            while (true) {
                const bytes = stream.read(conn.recvBuf()) catch |err| switch (err) {
                    error.WouldBlock => {
                        if (is_keepalive and is_first) {
                            metrics.timeoutKeepalive(1);
                        } else {
                            metrics.timeoutActive(1);
                        }
                        return .close;
                    },
                    error.NotOpenForReading => {
                        // This can only happen when we're shutting down and our
                        // listener has called posix.close(socket) to unblock
                        // this thread. Using `.disown` is a bit of a hack, but
                        // disown is handled in handleConnection the way we want
                        // WE DO NOT WANT to return .close, else that would result
                        // in posix.close(socket) being called on an already-closed
                        // socket, which would panic.
                        return .disown;
                    },
                    else => return .close,
                };
                conn.received(bytes);
                const done = req_state.parse(conn.req_arena.allocator()) catch |err| {
                    requestParseError(conn, err) catch {};
                    return .close;
                };
                if (done) {
                    // we have a complete request, time to process it
                    break;
                }

                if (is_keepalive) {
                    if (is_first) {
                        if (self.timeout_request) |to| {
                            // This was the first data from a keepalive request.
                            // We would have been on a keepalive timeout (if there was one),
                            // and now need to switch to a request timeout. This might be
                            // an actual timeout, or it could just be removing the keepalive timeout
                            // either way, it's the same code (timeval will just be set to 0 for
                            // the second case)
                            deadline = timestamp() + to.sec;
                            try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &to.timeval);
                        }
                        is_first = false;
                    }
                } else if (deadline) |dl| {
                    if (timestamp() > dl) {
                        metrics.timeoutActive(1);
                        return .close;
                    }
                }
            }

            metrics.request();
            self.server.handleRequest(conn, thread_buf);
            return conn.handover;
        }

        fn handleWebSocket(self: *const Self, hc: *ws.HandlerConn(WSH)) !void {
            posix.setsockopt(hc.socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(posix.timeval{ .sec = 0, .usec = 0 })) catch |err| {
                self.websocket.cleanupConn(hc);
                return err;
            };
            // closes the connection before returning
            return self.websocket.worker.readLoop(hc);
        }
    };
}

// This is a NonBlocking worker. We have N workers, each accepting connections
// and largely working in isolation from each other (the only thing they share
// is the *const config, a reference to the Server and to the Websocket server).
// The bulk of the code in this file exists to support the NonBlocking Worker.
// Our listening socket is nonblocking
// Request sockets are blocking. WHAT?  We'll use epoll/kqueue to know when
// a read wouldn't block. But we want writes to block because we want a nice
// and easy API for the app by giving their response a predictable/controllable
// lifetime.
// A previous version had the sockets in nonblocking and would switch to blocking
// as necessary, but I don't see what value that adds. It's just more syscalls
// and complexity.
pub fn NonBlocking(comptime S: type, comptime WSH: type) type {
    return struct {
        server: S,

        // KQueue or Epoll, depending on the platform
        loop: Loop,

        allocator: Allocator,

        // Manager of connections. This includes a list of active connections the
        // worker is responsible for, as well as buffer connections can use to
        // get larger []u8, and a pool of re-usable connection objects to reduce
        // dynamic allocations needed for new requests.
        manager: ConnManager(WSH),

        // the maximum connection a worker should manage, we won't accept more than this
        max_conn: usize,

        config: *const Config,

        signal: *Signal,

        websocket: *ws.Worker(WSH),

        // whether or not the worker is full (manager.len == max_conn)
        full: bool,

        // how many bytes should we retain in our arena allocator between keepalive usage
        retain_allocated_bytes_keepalive: usize,

        const Self = @This();

        const Loop = switch (LoopType) {
            .kqueue => KQueue(WSH),
            .iouring => IOUring(WSH),
            else => unreachable,
        };

        pub fn init(allocator: Allocator, listener: posix.fd_t, signal_pipe: [2]posix.fd_t, server: S, config: *const Config) !Self {
            const websocket = try allocator.create(ws.Worker(WSH));
            errdefer allocator.destroy(websocket);
            websocket.* = try ws.Worker(WSH).init(allocator, &server._websocket_state);
            errdefer websocket.deinit();

            const signal = try allocator.create(Signal);
            errdefer allocator.destroy(signal);
            signal.* = .{ .read_fd = signal_pipe[0], .write_fd = signal_pipe[1] };

            var manager = try ConnManager(WSH).init(allocator, websocket, config);
            errdefer manager.deinit();

            const retain_allocated_bytes = config.workers.retain_allocated_bytes orelse 4096;
            const retain_allocated_bytes_keepalive = @max(retain_allocated_bytes, 8192);

            const loop = try Loop.init(signal, listener);
            errdefer loop.deinit();

            return .{
                .full = false,
                .loop = loop,
                .signal = signal,
                .config = config,
                .server = server,
                .manager = manager,
                .websocket = websocket,
                .allocator = allocator,
                .max_conn = config.workers.max_conn orelse 8_192,
                .retain_allocated_bytes_keepalive = retain_allocated_bytes_keepalive,
            };
        }

        pub fn deinit(self: *Self) void {
            self.websocket.deinit();
            self.allocator.destroy(self.signal);
            self.allocator.destroy(self.websocket);
            self.manager.deinit();
            self.loop.deinit();
        }

        pub fn run(self: *Self) void {
            const manager = &self.manager;

            self.loop.monitorAccept() catch |err| {
                log.err("Failed to add monitor to listening socket: {}", .{err});
                return;
            };

            self.loop.monitorSignal() catch |err| {
                log.err("Failed to add monitor to signal pipe: {}", .{err});
                return;
            };

            var now = timestamp();
            var thread_pool = self.server._thread_pool;

            while (true) {
                const timeout = manager.prepareToWait(now);
                var it = self.loop.wait(timeout) catch |err| {
                    log.err("Failed to wait on events: {}", .{err});
                    std.time.sleep(std.time.ns_per_s);
                    continue;
                };
                now = timestamp();
                var closed_conn = false;

                while (it.next()) |completion| {
                    switch (completion) {
                        .recv => |conn| thread_pool.spawn(.{self, conn}),
                        .accept => |*a| self.accept(a, now) catch |err| {
                            log.err("Failed post-process accept: {}", .{err});
                            return;
                        },
                        .signal => |signal_it| self.processSignal(signal_it, now, &closed_conn) catch |err| {
                            log.err("Failed post-process signal: {}", .{err});
                            return;
                        },
                        .close => |conn| {
                            manager.close(conn);
                            closed_conn = true;
                        },
                        .shutdown => {
                            self.websocket.shutdown();
                            return;
                        },
                    }
                }

                // thread pool batches spawns (to minimize locking), so we need
                // to do a final flush since we probably have an incomplete batch
                const batch_size = thread_pool.batch_size;
                if (batch_size > 0) {
                    thread_pool.flush(batch_size);
                }

                // TODO: LOOP
                if (comptime LoopType == .kqueue) {
                    if (self.full and closed_conn) {
                        self.loop.monitorAccept() catch |err| {
                            log.err("Failed to enable monitor to listening socket: {}", .{err});
                            return;
                        };
                    }
                }
            }
        }

        fn accept(self: *Self, a: *const Completion(WSH).Accept, now: u32) !void {
            const socket = a.socket;
            errdefer posix.close(socket);
            metrics.connection();

            const flags = try posix.fcntl(socket, posix.F.GETFL, 0);
            const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
            // make sure it's in nonblocking
            if (flags & nonblocking != nonblocking) {
                // Yup, it's in nonblocking mode. Disable that flag to
                // put it in blocking mode.
                _ = try posix.fcntl(socket, posix.F.SETFL, flags & nonblocking);
            }

            const manager = &self.manager;
            const conn, const len = try manager.new(now);
            errdefer manager.close(conn);

            var http_conn = conn.protocol.http;
            http_conn.stream = .{ .handle = socket };
            http_conn.address = a.address;
            http_conn.flags = flags;

            try self.loop.monitorRead(conn, false);

            // TODO: LOOP
            if (comptime LoopType == .iouring) {
                if (len < self.max_conn) {
                    try self.loop.monitorAccept();
                }
            } else {
                if (len == self.max_conn) {
                    try self.loop.pauseAccept();
                }
            }
        }

        fn processSignal(self: *Self, it: Signal.Iterator, now: u32, closed_bool: *bool) !void {
            var it_ = it;
            const manager = &self.manager;

            while (it_.next()) |data| {
                const conn: *Conn(WSH) = @ptrFromInt(data);

                // wesocket doesn't use the signaling mechanism
                const http_conn = conn.protocol.http;
                switch (http_conn.handover) {
                    .keepalive => {
                        manager.keepalive(conn, now);
                        self.loop.monitorRead(conn, true) catch {
                            metrics.internalError();
                            manager.close(conn);
                            continue;
                        };
                    },
                    .need_data => {
                        manager.active(conn, now);
                        self.loop.monitorRead(conn, true) catch {
                            metrics.internalError();
                            manager.close(conn);
                            continue;
                        };
                    },
                    .close, .unknown => {
                        closed_bool.* = true;
                        manager.close(conn);
                    },
                    .disown => {
                        closed_bool.* = true;
                        if (self.loop.remove(conn)) {
                            manager.disown(conn);
                        } else |_| {
                            manager.close(conn);
                        }
                    },
                    .websocket => |ptr| {
                        closed_bool.* = true;
                        if (comptime WSH == httpz.DummyWebsocketHandler) {
                            std.debug.print("Your httpz handler must have a `WebsocketHandler` declaration. This must be the same type passed to `httpz.upgradeWebsocket`. Closing the connection.\n", .{});
                            manager.close(conn);
                            continue;
                        }
                        const hc: *ws.HandlerConn(WSH) = @ptrCast(@alignCast(ptr));
                        manager.upgrade(conn, hc);
                        self.loop.monitorRead(conn, true) catch {
                            metrics.internalError();
                            manager.close(conn);
                            continue;
                        };
                    },
                }
            }

            if (comptime LoopType == .iouring) {
                return self.loop.monitorSignal();
            }
        }

        // Entry-point of our thread pool. `thread_buf` is a thread-specific buffer
        // that we are free to use as needed.
        // Currently, for an HTTP connection, this is only called when we have a
        // full HTTP request ready to process. For an WebSocket packet, it's called
        // when we have data available - there may or may not be a full message ready
        pub fn processData(self: *Self, conn: *Conn(WSH), thread_buf: []u8) void {
            switch (conn.protocol) {
                .http => self.processHTTPData(conn, thread_buf),
                .websocket => self.processWebsocketData(conn, thread_buf),
            }
        }

        pub fn processHTTPData(self: *Self, conn: *Conn(WSH), thread_buf: []u8) void {
            var http_conn = conn.protocol.http;
            defer self.signal.write(@intFromPtr(conn)) catch @panic("todo");
            const done = http_conn.req_state.parse(http_conn.req_arena.allocator()) catch |err| {
                requestParseError(http_conn, err) catch {};
                http_conn.handover = .close;
                return;
            };

            if (done == false) {
                http_conn.handover = .need_data;
                return;
            }

            metrics.request();
            http_conn.request_count += 1;
            self.server.handleRequest(http_conn, thread_buf);

            if (http_conn.handover == .keepalive) {
                 // Do what we can in the threadpool to setup this connection for
                // more work. Anything we _don't_ do here has to be done in the worker
                // thread, which impacts all connections. But, we can only do stuff
                // that's thread-safe here (i.e. we can't manipulate the ConnManager)
                http_conn.keepalive(self.retain_allocated_bytes_keepalive);
            }
        }

        pub fn processWebsocketData(self: *Self, conn: *Conn(WSH), thread_buf: []u8) void {
            var hc = conn.protocol.websocket;
            var ws_conn = &hc.conn;
            const success = self.websocket.worker.dataAvailable(hc, thread_buf);
            if (success == false) {
                ws_conn.close(.{ .code = 4997, .reason = "wsz" }) catch {};
                self.websocket.cleanupConn(hc);
            } else if (ws_conn.isClosed()) {
                self.websocket.cleanupConn(hc);
            } else {
                self.loop.monitorRead(conn, true) catch |err| {
                    log.debug("({}) failed to add read event monitor: {}", .{ ws_conn.address, err });
                    ws_conn.close(.{ .code = 4998, .reason = "wsz" }) catch {};
                    self.websocket.cleanupConn(hc);
                };
            }
        }
    };
}

// We use a pipe to communicate with the NonBlocking worker. This is necessary
// since the NonBlocking worker is likely blocked on a loop (epoll/kqueue wait).
// So we add one end of the pipe (the "read" end) to the loop.
// The write end is used for 2 things:
// 1  - The httpz.Server(H) has a copy of the write-end and can close it
//      this is how the server signals the worker to shutdown.
// 2  - The NonBlocking worker also has ac opy of the write-end. This is used
//      by the `serveHTTPRequest` method, which is executed in a thread-pool thread,
//      to transfer control back to the worker.
//
// I did experiment with options to remove #2, namely by having the thread-pool
// direclty handle the handover. Essentially moving `processSignal` which is
// run in the NonBlocking worker's thread, to `serveHTTPRequest` which is run
// in the thread-pool thread. But this adds a lot of complexity and a lot of
// locking overhead. The entire ConnManager has to become thread-safe - synchronizing
// access to the active/keepalive lists, the memory and conn pools...
const Signal = struct {
    const BUF_LEN = 4096;

    // synhronizes writes to the write_fd, since we're going to be writing to
    // write_fd from the thread-pool theads
    mut: Thread.Mutex = .{},
    write_fd: posix.fd_t,

    pos: usize = 0,
    read_fd: posix.fd_t,
    buf: [BUF_LEN]u8 = undefined,

    // Called in the thread-pool thread to let the worker know that this connection
    // is being handed back to the worker.
    fn write(self: *Signal, data: usize) !void {
        const fd = self.write_fd;
        const buf = std.mem.asBytes(&data);

        self.mut.lock();
        defer self.mut.unlock();

        var index: usize = 0;
        while (index < buf.len) {
            index += posix.write(fd, buf[index..]) catch |err| switch (err) {
                error.NotOpenForWriting => return, // signal was closed, we must be shutting down
                else => return err,
            };
        }
    }

    fn iterator(self: *Signal, size: usize) Iterator {
        const pos = self.pos + size;
        self.pos = pos;
        return .{
            .signal = self,
            .buf = self.buf[0..pos],
        };
    }

    const Iterator = struct {
        signal: *Signal,
        buf: []const u8,

        fn next(self: *Iterator) ?usize {
            const buf = self.buf;

            if (buf.len < @sizeOf(usize)) {
                if (buf.len == 0) {
                    // this is going to happen 99% of the time, so while we
                    // could merge the if/else cases easily, it would add a tiny
                    // bit of overhead for this very common case
                    self.signal.pos = 0;
                } else {
                    std.mem.copyForwards(u8, &self.signal.buf, buf);
                    self.signal.pos = buf.len;
                }
                return null;
            }

            const data = buf[0..@sizeOf(usize)];
            self.buf = buf[@sizeOf(usize)..];
            return std.mem.bytesToValue(usize, data);
        }
    };
};

fn ConnManager(comptime WSH: type) type {
    return struct {
        // Double linked list of Conn a worker is actively servicing. An "active"
        // connection is one where we've at least received 1 byte of the request and
        // continues to be "active" until the response is sent.
        active_list: List(Conn(WSH)),

        // Double linked list of Conn a worker is monitoring. Unlike "active" connections
        // these connections are between requests (which is possible due to keepalive).
        keepalive_list: List(Conn(WSH)),

        // # of active connections we're managing. This is the length of our list.
        len: usize,

        // A pool of HTTPConn objects. The pool maintains a configured min # of these.
        http_conn_pool: HTTPConnPool,

        // For creating the Conn wrapper. We need these on the heap since that's
        // what we pass to our event loop as the data to pass back to us.
        conn_mem_pool: std.heap.MemoryPool(Conn(WSH)),

        // Request and response processing may require larger buffers than the static
        // buffered of our req/res states. The BufferPool has larger pre-allocated
        // buffers that can be used and, when empty or when a larger buffer is needed,
        // will do dynamic allocation
        buffer_pool: *BufferPool,

        allocator: Allocator,

        timeout_request: u32,
        timeout_keepalive: u32,

        const Self = @This();

        fn init(allocator: Allocator, websocket: *anyopaque, config: *const Config) !Self {
            var buffer_pool = try initializeBufferPool(allocator, config);
            errdefer buffer_pool.deinit();

            var conn_mem_pool = std.heap.MemoryPool(Conn(WSH)).init(allocator);
            errdefer conn_mem_pool.deinit();

            const http_conn_pool = try HTTPConnPool.init(allocator, buffer_pool, websocket, config);
            errdefer http_conn_pool.deinit();

            return .{
                .len = 0,
                .active_list = .{},
                .keepalive_list = .{},
                .allocator = allocator,
                .buffer_pool = buffer_pool,
                .conn_mem_pool = conn_mem_pool,
                .http_conn_pool = http_conn_pool,
                .timeout_request = config.timeout.request orelse MAX_TIMEOUT,
                .timeout_keepalive = config.timeout.keepalive orelse MAX_TIMEOUT,
            };
        }

        pub fn deinit(self: *Self) void {
            self.shutdownList(&self.active_list);
            self.shutdownList(&self.keepalive_list);

            const allocator = self.allocator;
            self.buffer_pool.deinit();
            self.conn_mem_pool.deinit();
            self.http_conn_pool.deinit();
            allocator.destroy(self.buffer_pool);
        }

        fn new(self: *Self, now: u32) !struct{*Conn(WSH), usize} {
            const conn = try self.conn_mem_pool.create();
            errdefer self.conn_mem_pool.destroy(conn);

            const http_conn = try self.http_conn_pool.acquire();
            http_conn.state = .active;
            http_conn.request_count = 1;
            http_conn.timeout = now + self.timeout_request;

            conn.* = .{
                .next = null,
                .prev = null,
                .protocol = .{ .http = http_conn },
            };
            self.active_list.insert(conn);

            const len = self.len + 1;
            self.len = len;

            return .{conn, len};
        }

        fn active(self: *Self, conn: *Conn(WSH), now: u32) void {
            var http_conn = conn.protocol.http;
            if (http_conn.state == .active) return;

            // If we're here, it means the connection is going from a keepalive
            // state to an active state.

            http_conn.state = .active;
            http_conn.timeout = now + self.timeout_request;

            self.keepalive_list.remove(conn);
            self.active_list.insert(conn);
        }

        fn keepalive(self: *Self, conn: *Conn(WSH), now: u32) void {
            var http_conn = conn.protocol.http;
            if (http_conn.state == .keepalive) return;

            // we expect the threadpool to have already called http_conn.keepalive()
            http_conn.state = .keepalive;
            http_conn.timeout = now + self.timeout_keepalive;
            self.active_list.remove(conn);
            self.keepalive_list.insert(conn);
        }

        fn close(self: *Self, conn: *Conn(WSH)) void {
            conn.close();
            self.disown(conn);
        }

        fn disown(self: *Self, conn: *Conn(WSH)) void {
            switch (conn.protocol) {
                .http => |http_conn| {
                    switch (http_conn.state) {
                        .active => self.active_list.remove(conn),
                        // a connection in "keepalive" can't be disowned, but
                        // it can be closed (by timeout), and close calls disown.
                        .keepalive => self.keepalive_list.remove(conn),
                    }
                    self.http_conn_pool.release(http_conn);
                },
                .websocket => {},
            }

            self.len -= 1;
            self.conn_mem_pool.destroy(conn);
        }

        fn upgrade(self: *Self, conn: *Conn(WSH), hc: *ws.HandlerConn(WSH)) void {
            std.debug.assert(conn.protocol.http.state == .active);
            self.active_list.remove(conn);
            self.http_conn_pool.release(conn.protocol.http);
            conn.protocol = .{ .websocket = hc };
        }

        fn shutdownList(self: *Self, list: *List(Conn(WSH))) void {
            const allocator = self.allocator;

            var conn = list.head;
            while (conn) |c| {
                conn = c.next;
                const http_conn = c.protocol.http;
                posix.close(http_conn.stream.handle);
                http_conn.deinit(allocator);
            }
        }

        // Enforces timeouts, and returns when the next timeout should be checked.
        fn prepareToWait(self: *Self, now: u32) ?i32 {
            const next_active = self.enforceTimeout(&self.active_list, now);
            const next_keepalive = self.enforceTimeout(&self.keepalive_list, now);

            {
                const next_active_count = next_active.count;
                if (next_active_count > 0) {
                    metrics.timeoutActive(next_active_count);
                }
                const next_keepalive_count = next_keepalive.count;
                if (next_keepalive_count > 0) {
                    metrics.timeoutKeepalive(next_active_count);
                }
            }

            const next_active_timeout = next_active.timeout;
            const next_keepalive_timeout = next_keepalive.timeout;
            if (next_active_timeout == null and next_keepalive_timeout == null) {
                return null;
            }

            const next = @min(next_active_timeout orelse MAX_TIMEOUT, next_keepalive_timeout orelse MAX_TIMEOUT);
            if (next < now) {
                // can happen if a socket was just about to time out when enforceTimeout
                // was called
                return 1;
            }

            return @intCast(next - now);
        }

        const TimeoutResult = struct {
            count: usize,
            timeout: ?u32,
        };

        // lists are ordered from soonest to timeout to last, as soon as we find
        // a connection that isn't timed out, we can break;
        // This returns the next timeout.
        // Only called on the active and keepalive lists, which only handle
        // http connections.
        fn enforceTimeout(self: *Self, list: *List(Conn(WSH)), now: u32) TimeoutResult {
            var conn = list.head;
            var count: usize = 0;
            while (conn) |c| {
                const timeout = c.protocol.http.timeout;
                if (timeout > now) {
                    return .{ .count = count, .timeout = timeout };
                }
                count += 1;
                conn = c.next;
                self.close(c);
            }
            return .{ .count = count, .timeout = null };
        }
    };
}

pub fn List(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,

        const Self = @This();

        pub fn insert(self: *Self, node: *T) void {
            if (self.tail) |tail| {
                tail.next = node;
                node.prev = tail;
                self.tail = node;
            } else {
                self.head = node;
                self.tail = node;
            }
            node.next = null;
        }

        pub fn moveToTail(self: *Self, node: *T) void {
            // orelse, it's already the tail
            const next = node.next orelse return;
            const prev = node.prev;

            if (prev) |p| {
                p.next = next;
            } else {
                self.head = next;
            }

            next.prev = prev;
            node.prev = self.tail;
            node.prev.?.next = node;
            self.tail = node;
            node.next = null;
        }

        pub fn remove(self: *Self, node: *T) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
            node.prev = null;
            node.next = null;
        }
    };
}

fn KQueue(comptime WSH: type) type {
    return struct {
        q: i32,
        signal: *Signal,
        listener: posix.fd_t,
        change_count: usize,
        change_buffer: [32]Kevent,
        event_list: [128]Kevent,

        const Kevent = posix.Kevent;

        const Self = @This();

        fn init(signal: *Signal, listener: posix.fd_t) !Self {
            return .{
                .signal = signal,
                .change_count = 0,
                .listener = listener,
                .q = try posix.kqueue(),
                .event_list = undefined,
                .change_buffer = undefined,
            };
        }

        fn deinit(self: *Self) void {
            posix.close(self.q);
        }

        fn monitorAccept(self: *Self) !void {
            try self.change(self.listener, 0, posix.system.EVFILT.READ, posix.system.EV.ENABLE | posix.system.EV.ADD);
        }

        fn pauseAccept(self: *Self) !void {
            try self.change(self.listener, 0, posix.system.EVFILT.READ, posix.system.EV.DISABLE);
        }

        fn monitorSignal(self: *Self) !void {
            try self.change(self.signal.read_fd, 1, posix.system.EVFILT.READ, posix.system.EV.ADD);
        }

        fn monitorRead(self: *Self, conn: *Conn(WSH), comptime rearm: bool) !void {
            if (rearm) {
                // for websocket connections, this is called in a thread-pool thread
                // so cannot be queued up - it needs to be immediately picked up
                // since our worker could be in a wait() call.
                const event = Kevent{
                    .ident = @intCast(conn.getSocket()),
                    .filter = posix.system.EVFILT.READ,
                    .flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.DISPATCH,
                    .fflags = 0,
                    .data = 0,
                    .udata = @intFromPtr(conn),
                };
                _ = try posix.kevent(self.q, &.{event}, &[_]Kevent{}, null);
            } else {
                try self.change(conn.getSocket(), @intFromPtr(conn), posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.DISPATCH);
            }
        }

        fn remove(self: *Self, conn: *Conn(WSH)) !void {
            try self.change(conn.getSocket(), 0, posix.system.EVFILT.READ, posix.system.EV.DELETE);
        }

        fn change(self: *Self, fd: posix.fd_t, data: usize, filter: i16, flags: u16) !void {
            var change_count = self.change_count;
            var change_buffer = &self.change_buffer;

            if (change_count == change_buffer.len) {
                // calling this with an empty event_list will return immediate
                _ = try posix.kevent(self.q, change_buffer, &[_]Kevent{}, null);
                change_count = 0;
            }
            change_buffer[change_count] = .{
                .ident = @intCast(fd),
                .filter = filter,
                .flags = flags,
                .fflags = 0,
                .data = 0,
                .udata = data,
            };
            self.change_count = change_count + 1;
        }

        fn wait(self: *Self, timeout_sec: ?i32) !Iterator {
            const event_list = &self.event_list;
            const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .sec = ts, .nsec = 0 } else null;
            const event_count = try posix.kevent(self.q, self.change_buffer[0..self.change_count], event_list, if (timeout) |ts| &ts else null);
            self.change_count = 0;

            return .{
                .index = 0,
                .loop = self,
                .events = event_list[0..event_count],
            };
        }

        const Iterator = struct {
            loop: *Self,
            index: usize,
            events: []Kevent,

            fn next(self: *Iterator) ?Completion(WSH) {
                const index = self.index;
                const events = self.events;
                self.index = index + 1;

                if (index == events.len) {
                    return null;
                }
                const event = &self.events[index];

                const user_data = event.udata;

                switch(user_data) {
                    0 => {
                        var address: net.Address = undefined;
                        var address_len: posix.socklen_t = @sizeOf(net.Address);
                        const socket = posix.accept(self.loop.listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
                            log.err("Error accepting: {}", .{err});
                            return .{.shutdown = {}};
                        };
                        return .{.accept = .{.socket = socket, .address = address}};
                    },
                    1 => {
                        const signal = self.loop.signal;
                        std.debug.assert(signal.pos < signal.buf.len);

                        const n = posix.read(signal.read_fd, signal.buf[signal.pos..]) catch 0;
                        if (n == 0) {
                            return .{.shutdown = {}};
                        }
                        return .{.signal = signal.iterator(@intCast(n))};
                    },
                    else => {
                        var conn: *Conn(WSH) = @ptrFromInt(user_data);

                        if (event.flags & posix.system.EV.EOF == posix.system.EV.EOF) {
                            return .{.close = conn};
                        }

                        const n = posix.read(conn.getSocket(), conn.recvBuf()) catch return .{.close = conn};
                        if (n == 0) {
                            return .{.close = conn};
                        }
                        conn.received(@intCast(n));
                        return .{.recv = conn};
                    }
                }
            }
        };
    };
}

fn IOUring(comptime WSH: type) type {
    const linux = std.os.linux;

    return struct {
        ring: linux.IoUring,
        signal: *Signal,
        listener: Listener,
        cqes: [16]linux.io_uring_cqe,

        const Self = @This();

        const Listener = struct {
            socket: posix.fd_t,
            address: net.Address = undefined,
            address_len: posix.socklen_t = @sizeOf(net.Address),
        };

        fn init(signal: *Signal, listener: posix.fd_t) !Self {
            return .{
                .cqes = undefined,
                .signal = signal,
                .listener = .{.socket = listener},
                .ring = try linux.IoUring.init(32, 0),
            };
        }

        fn deinit(self: *Self) void {
            self.ring.deinit();
        }

        fn monitorAccept(self: *Self) !void {
            const listener = &self.listener;
            var sqe = try self.getSqe();
            sqe.prep_accept(listener.socket, &listener.address.any, &listener.address_len, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK);
            sqe.user_data = 0;
        }

        fn pauseAccept(_: *Self) !void {
            // should not be called on IOuring
            unreachable;
        }

        fn monitorSignal(self: *Self) !void {
            const signal = self.signal;
            std.debug.assert(signal.pos < signal.buf.len);

            var sqe = try self.getSqe();
            sqe.prep_read(signal.read_fd, signal.buf[signal.pos..], 0);
            sqe.user_data = 1;
        }

        fn monitorRead(self: *Self, conn: *Conn(WSH), comptime rearm: bool) !void {
            _ = rearm;
            const buf = conn.recvBuf();
            std.debug.assert(buf.len > 0);

            var sqe = try self.getSqe();
            sqe.prep_recv(conn.getSocket(), buf, 0);
            sqe.user_data = @intFromPtr(conn);
        }

        fn remove(self: *Self, fd: posix.fd_t) !void {
            _ = self;
            _ = fd;
        }

        fn getSqe(self: *Self,) !*linux.io_uring_sqe {
            var ring = &self.ring;
            while (true) {
                return ring.get_sqe() catch |err| switch (err) {
                    error.SubmissionQueueFull => {
                        _ = ring.submit() catch |err2| switch (err2) {
                            error.SignalInterrupt => {},
                            else => return err2,
                        };
                        continue;
                    }
                };
            }
        }

        fn wait(self: *Self, timeout_sec: ?i32) !Iterator {
            _ = timeout_sec;
            while (true) {
                _ = self.ring.submit_and_wait(1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return err,
                };

                const count = self.ring.copy_cqes(&self.cqes, 1) catch |err| switch (err) {
                    error.SignalInterrupt => continue,
                    else => return err,
                };

                return .{
                    .loop = self,
                    .cqes = self.cqes[0..count],
                };
            }
        }

        const Iterator = struct {
            loop: *Self,
            cqes: []linux.io_uring_cqe,

            fn next(self: *Iterator) ?Completion(WSH) {
                const cqes = self.cqes;
                if (cqes.len == 0) {
                    return null;
                }

                const cqe = cqes[0];
                self.cqes = cqes[1..];

                const res = cqe.res;
                const user_data = cqe.user_data;

                if (res < 0) {
                    switch (user_data) {
                        0 => {
                            log.err("Error accepting: {}", .{@as(posix.E, @enumFromInt(-res))});
                            return .{.shutdown = {}};
                        },
                        1 => {
                            log.err("Error reading signal pipe: {}", .{@as(posix.E, @enumFromInt(-res))});
                            return .{.shutdown = {}};
                        },
                        else => return .{.close = @ptrFromInt(user_data)},
                    }
                }

                switch(user_data) {
                    0 => return .{.accept = .{.socket = res, .address = self.loop.listener.address}},
                    1 => {
                        if (res == 0) {
                            // signal closed, we're being told to shutdown
                            return .{.shutdown = {}};
                        }
                        return .{.signal = self.loop.signal.iterator(@intCast(res))};
                    },
                    else => {
                        var conn: *Conn(WSH) = @ptrFromInt(user_data);
                        if (res == 0) {
                            return .{.close = conn};
                        }
                        conn.received(@intCast(res));
                        return .{.recv = conn};
                    }
                }
            }
        };
    };
}

fn Completion(comptime WSH: type) type {
    return union(enum) {
        accept: Accept,
        shutdown: void,
        recv: *Conn(WSH),
        close: *Conn(WSH),
        signal: Signal.Iterator,

        const Accept = struct {
            socket: posix.fd_t,
            address: net.Address,
        };
    };
}

// There's some shared logic between the NonBlocking and Blocking workers.
// Whatever we can de-duplicate, goes here.
const HTTPConnPool = struct {
    mut: Thread.Mutex,
    conns: []*HTTPConn,
    available: usize,
    allocator: Allocator,
    config: *const Config,
    buffer_pool: *BufferPool,
    retain_allocated_bytes: usize,
    http_mem_pool_mut: Thread.Mutex,
    http_mem_pool: std.heap.MemoryPool(HTTPConn),

    // we erase the type because we don't want Conn, and therefore Request and
    // Response to have to carry this type around. This is all about making the
    // API cleaner.
    websocket: *anyopaque,

    fn init(allocator: Allocator, buffer_pool: *BufferPool, websocket: *anyopaque, config: *const Config) !HTTPConnPool {
        const min = config.workers.min_conn orelse @min(config.workers.max_conn orelse 64, 64);

        var conns = try allocator.alloc(*HTTPConn, min);
        errdefer allocator.free(conns);

        var http_mem_pool = std.heap.MemoryPool(HTTPConn).init(allocator);
        errdefer http_mem_pool.deinit();

        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| {
                conns[i].deinit(allocator);
            }
        }

        for (0..min) |i| {
            const conn = try http_mem_pool.create();
            conn.* = try HTTPConn.init(allocator, buffer_pool, websocket, config);

            conns[i] = conn;
            initialized += 1;
        }

        return .{
            .mut = .{},
            .conns = conns,
            .config = config,
            .available = min,
            .websocket = websocket,
            .allocator = allocator,
            .buffer_pool = buffer_pool,
            .http_mem_pool = http_mem_pool,
            .http_mem_pool_mut = .{},
            .retain_allocated_bytes = config.workers.retain_allocated_bytes orelse 4096,
        };
    }

    fn deinit(self: *HTTPConnPool) void {
        const allocator = self.allocator;
        // the rest of the conns are "checked out" and owned by the Manager
        // whichi will free them.
        for (self.conns[0..self.available]) |conn| {
            conn.deinit(allocator);
        }
        allocator.free(self.conns);
        self.http_mem_pool.deinit();
    }

    fn acquire(self: *HTTPConnPool) !*HTTPConn {
        const conns = self.conns;

        self.lock();
        const available = self.available;
        if (available == 0) {
            self.unlock();

            self.http_mem_pool_mut.lock();
            const conn = try self.http_mem_pool.create();
            self.http_mem_pool_mut.unlock();
            errdefer {
                self.http_mem_pool_mut.lock();
                self.http_mem_pool.destroy(conn);
                self.http_mem_pool_mut.unlock();
            }

            conn.* = try HTTPConn.init(self.allocator, self.buffer_pool, self.websocket, self.config);
            return conn;
        }

        const index = available - 1;
        const conn = conns[index];
        self.available = index;
        self.unlock();
        return conn;
    }

    fn release(self: *HTTPConnPool, conn: *HTTPConn) void {
        const conns = self.conns;

        self.lock();
        const available = self.available;
        if (available == conns.len) {
            self.unlock();
            conn.deinit(self.allocator);

            self.http_mem_pool_mut.lock();
            self.http_mem_pool.destroy(conn);
            self.http_mem_pool_mut.unlock();
            return;
        }

        conn.reset(self.retain_allocated_bytes);
        conns[available] = conn;
        self.available = available + 1;
        self.unlock();
    }

    // don't need thread safety in nonblocking
    fn lock(self: *HTTPConnPool) void {
        if (comptime httpz.blockingMode()) {
            self.mut.lock();
        }
    }

    // don't need thread safety in nonblocking
    fn unlock(self: *HTTPConnPool) void {
        if (comptime httpz.blockingMode()) {
            self.mut.unlock();
        }
    }
};

pub fn Conn(comptime WSH: type) type {
    return struct {
        protocol: union(enum) {
            http: *HTTPConn,
            websocket: *ws.HandlerConn(WSH),
        },

        // Node in a List(WSH). List is [obviously] intrusive.
        next: ?*Conn(WSH),
        prev: ?*Conn(WSH),

        const Self = @This();

        fn close(self: *Self) void {
            switch (self.protocol) {
                .http => |hc| posix.close(hc.stream.handle),
                .websocket => |hc| hc.conn.close(.{}) catch {},
            }
        }

        pub fn getSocket(self: Self) posix.fd_t {
            return switch (self.protocol) {
                .http => |hc| hc.stream.handle,
                .websocket => |hc| hc.socket,
            };
        }

        fn recvBuf(self: Self) []u8 {
            return switch (self.protocol) {
                .http => |hc| hc.recvBuf(),
                .websocket => |_| @panic("TODO"),
            };
        }


        fn received(self: Self, bytes: usize) void {
            std.debug.assert(bytes > 0);
            return switch (self.protocol) {
                .http => |hc| hc.received(bytes),
                .websocket => |_| @panic("TODO"),
            };
        }
    };
}

// Wraps a socket with a application-specific details, such as information needed
// to manage the connection's lifecycle (e.g. timeouts). Conns are placed in a
// linked list, hence the next/prev.
//
// The Conn can be re-used (as parf of a pool), either for keepalive, or for
// completely different tcp connections. From the Conn's point of view, there's
// no difference, just need to `reset` between each request.
//
// The Conn contains request and response state information necessary to operate
// in nonblocking mode. A pointer to the conn is the userdata passed to epoll/kqueue.
// Should only be created through the worker's HTTPConnPool
pub const HTTPConn = struct {
    // A connection can be in one of two states: active or keepalive. It begins
    // and stays in "active" until the response is sent. Then, assuming the
    // connection isn't closed, it transitions to "keepalive" until the first
    // byte of a new request is received.
    // The main purpose of the two different states is to support a different
    // keepalive_timeout and request_timeout.
    const State = enum {
        active,
        keepalive,
    };

    pub const Handover = union(enum) {
        disown,
        close,
        unknown,
        keepalive,
        need_data,
        websocket: *anyopaque,
    };

    state: State,

    handover: Handover,

    // unix timestamp (seconds) where this connection should timeout
    timeout: u32,

    // number of requests made on this connection (within a keepalive session)
    request_count: u64,

    // whether or not to close the connection after the response is sent
    close: bool,

    stream: net.Stream,
    address: net.Address,

    // Data needed to parse a request. This contains pre-allocated memory, e.g.
    // as a read buffer and to store parsed headers. It also contains the state
    // necessary to parse the request over successive nonblocking read calls.
    req_state: Request.State,

    // Data needed to create the response. This contains pre-allocate memory, .e.
    // header buffer to write the buffer. It also contains the state necessary
    // to write the response over successive nonblocking write calls.
    res_state: Response.State,

    // Memory that is needed for the lifetime of a request, specifically from the
    // point where the request is parsed to after the response is sent, can be
    // allocated in this arena. An allocator for this arena is available to the
    // application as req.arena and res.arena.
    req_arena: std.heap.ArenaAllocator,

    // Memory that is needed for the lifetime of the connection. In most cases
    // the connection outlives the request for two reasons: keepalive and the
    // fact that we keepa pool of connections.
    conn_arena: *std.heap.ArenaAllocator,

    // This is our ws.Worker(WSH) but the type is erased so that Conn isn't
    // a generic. We don't want Conn to be a generic, because we don't want Response
    // to be generics since that would make using the library unecessarily complex
    // (especially since not everyone cares about websockets).
    ws_worker: *anyopaque,

    // socket flags (used when we have to toggle blocking/nonblocking)
    flags: usize = 0,

    blocking: bool = false,

    fn init(allocator: Allocator, buffer_pool: *BufferPool, ws_worker: *anyopaque, config: *const Config) !HTTPConn {
        const conn_arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(conn_arena);

        conn_arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer conn_arena.deinit();

        const req_state = try Request.State.init(conn_arena.allocator(), buffer_pool, &config.request);
        const res_state = try Response.State.init(conn_arena.allocator(), &config.response);

        var req_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer req_arena.deinit();

        return .{
            .close = false,
            .state = .active,
            .handover = .unknown,
            .stream = undefined,
            .address = undefined,
            .req_state = req_state,
            .res_state = res_state,
            .req_arena = req_arena,
            .conn_arena = conn_arena,
            .timeout = 0,
            .request_count = 0,
            .ws_worker = ws_worker,
        };
    }

    pub fn deinit(self: *HTTPConn, allocator: Allocator) void {
        self.req_state.deinit();
        self.req_arena.deinit();
        self.conn_arena.deinit();
        allocator.destroy(self.conn_arena);
    }

    pub fn keepalive(self: *HTTPConn, retain_allocated_bytes: usize) void {
        self.req_state.reset();
        self.res_state.reset();
        _ = self.req_arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
    }

    pub fn makeBlocking(self: *HTTPConn) !void {
        std.debug.assert(self.blocking == false);
        const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.flags & ~nonblocking);
    }

    pub fn makeNonBlocking(self: *HTTPConn) !void {
        std.debug.assert(self.blocking == true);
        const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.flags & nonblocking);
    }

    // getting put back into the pool
    pub fn reset(self: *HTTPConn, retain_allocated_bytes: usize) void {
        self.close = false;
        self.handover = .unknown;
        self.request_count = 0;
        self.req_state.reset();
        self.res_state.reset();
        _ = self.req_arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
    }

    pub fn recvBuf(self: *const HTTPConn) []u8 {
        const state = &self.req_state;
        if (state.body) |b| {
            return b.data[state.body_pos..];
        }
        return state.buf[state.len..];
    }

    pub fn received(self: *HTTPConn, bytes: usize) void {
        const state = &self.req_state;
        if (state.body == null)  {
            state.len += bytes;
        } else {
            state.body_pos += bytes;
        }
    }

    pub fn writeAll(self: *HTTPConn, data: []const u8) !void {
        const stream = self.stream;
        while (true) {
            stream.writeAll(data) catch |err| {
                switch (err) {
                  error.WouldBlock => try self.makeBlocking(),
                 else => return err,
                }
            };
            return;
        }
    }

    pub fn writeAllIOVec(self: *HTTPConn, vec: []std.posix.iovec_const) !void {
        const socket = self.stream.handle;

        while (true) {
            var i: usize = 0;
            while (true) {
                var n = std.posix.writev(socket, vec[i..]) catch |err| switch (err) {
                    error.WouldBlock => {
                        try self.makeBlocking();
                        continue;
                    },
                    else => return err,
                };

                while (n >= vec[i].len) {
                    n -= vec[i].len;
                    i += 1;
                    if (i >= vec.len) return;
                }
                vec[i].base += n;
                vec[i].len -= n;
            }
        }
    }
};

pub fn timestamp() u32 {
    if (comptime @hasDecl(posix, "CLOCK") == false or posix.CLOCK == void) {
        return @intCast(std.time.timestamp());
    }
    var ts: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.REALTIME, &ts) catch unreachable;
    return @intCast(ts.sec);
}

fn initializeBufferPool(allocator: Allocator, config: *const Config) !*BufferPool {
    const large_buffer_count = config.workers.large_buffer_count orelse blk: {
        if (httpz.blockingMode()) {
            break :blk config.threadPoolCount();
        } else {
            break :blk 16;
        }
    };
    const large_buffer_size = config.workers.large_buffer_size orelse config.request.max_body_size orelse 65536;

    const buffer_pool = try allocator.create(BufferPool);
    errdefer allocator.destroy(buffer_pool);

    buffer_pool.* = try BufferPool.init(allocator, large_buffer_count, large_buffer_size);
    return buffer_pool;
}

// Handles parsing errors. If this returns true, it means Conn has a body ready
// to write. In this case the worker (blocking or nonblocking) will want to send
// the response. If it returns false, the worker probably wants to close the connection.
// This function ensures that both Blocking and NonBlocking workers handle these
// errors with the same response
fn requestParseError(conn: *HTTPConn, err: anyerror) !void {
    switch (err) {
        error.HeaderTooBig => {
            metrics.invalidRequest();
            return writeError(conn, 431, "Request header is too big");
        },
        error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine, error.InvalidContentLength => {
            metrics.invalidRequest();
            return writeError(conn, 400, "Invalid Request");
        },
        error.BrokenPipe, error.ConnectionClosed, error.ConnectionResetByPeer => return,
        else => return serverError(conn, "unknown read/parse error: {}", err),
    }
    log.err("unknown parse error: {}", .{err});
    return err;
}

fn serverError(conn: *HTTPConn, comptime log_fmt: []const u8, err: anyerror) !void {
    log.err("server error: " ++ log_fmt, .{err});
    metrics.internalError();
    return writeError(conn, 500, "Internal Server Error");
}

fn writeError(conn: *HTTPConn, comptime status: u16, comptime msg: []const u8) !void {
    const socket = conn.stream.handle;
    const response = std.fmt.comptimePrint("HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, msg.len, msg });

    var i: usize = 0;

    const timeout = std.mem.toBytes(std.posix.timeval{ .sec = 5, .usec = 0 });
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
    while (i < response.len) {
        const n = posix.write(socket, response[i..]) catch |err| switch (err) {
            error.WouldBlock => return error.Timeout,
            else => return err,
        };

        if (n == 0) {
            return error.Closed;
        }

        i += n;
    }
}

const t = @import("t.zig");
test "HTTPConnPool" {
    var bp = try BufferPool.init(t.allocator, 2, 64);
    defer bp.deinit();

    var p = try HTTPConnPool.init(t.allocator, &bp, undefined, &.{
        .workers = .{ .min_conn = 2 },
        .request = .{ .buffer_size = 64 },
    });
    defer p.deinit();

    const s1 = try p.acquire();
    const s2 = try p.acquire();
    const s3 = try p.acquire();

    try t.expectEqual(true, s1.req_state.buf.ptr != s2.req_state.buf.ptr);
    try t.expectEqual(true, s1.req_state.buf.ptr != s3.req_state.buf.ptr);
    try t.expectEqual(true, s2.req_state.buf.ptr != s3.req_state.buf.ptr);

    p.release(s2);
    const s4 = try p.acquire();
    try t.expectEqual(true, s4.req_state.buf.ptr == s2.req_state.buf.ptr);

    p.release(s1);
    p.release(s3);
    p.release(s4);
}

test "List: insert & remove" {
    var list = List(TestNode){};
    try expectList(&.{}, list);

    var n1 = TestNode{ .id = 1 };
    list.insert(&n1);
    try expectList(&.{1}, list);

    list.remove(&n1);
    try expectList(&.{}, list);

    var n2 = TestNode{ .id = 2 };
    list.insert(&n2);
    list.insert(&n1);
    try expectList(&.{ 2, 1 }, list);

    var n3 = TestNode{ .id = 3 };
    list.insert(&n3);
    try expectList(&.{ 2, 1, 3 }, list);

    list.remove(&n1);
    try expectList(&.{ 2, 3 }, list);

    list.insert(&n1);
    try expectList(&.{ 2, 3, 1 }, list);

    list.remove(&n2);
    try expectList(&.{ 3, 1 }, list);

    list.remove(&n1);
    try expectList(&.{3}, list);

    list.remove(&n3);
    try expectList(&.{}, list);
}

test "List: moveToTail" {
    var list = List(TestNode){};
    try expectList(&.{}, list);

    var n1 = TestNode{ .id = 1 };
    list.insert(&n1);
    // list.moveToTail(&n1);
    try expectList(&.{1}, list);

    var n2 = TestNode{ .id = 2 };
    list.insert(&n2);

    list.moveToTail(&n1);
    try expectList(&.{ 2, 1 }, list);

    list.moveToTail(&n1);
    try expectList(&.{ 2, 1 }, list);

    list.moveToTail(&n2);
    try expectList(&.{ 1, 2 }, list);

    var n3 = TestNode{ .id = 3 };
    list.insert(&n3);

    list.moveToTail(&n1);
    try expectList(&.{ 2, 3, 1 }, list);

    list.moveToTail(&n1);
    try expectList(&.{ 2, 3, 1 }, list);

    list.moveToTail(&n2);
    try expectList(&.{ 3, 1, 2 }, list);

    list.moveToTail(&n1);
    try expectList(&.{ 3, 2, 1 }, list);
}

const TestNode = struct {
    id: i32,
    next: ?*TestNode = null,
    prev: ?*TestNode = null,
};

fn expectList(expected: []const i32, list: List(TestNode)) !void {
    if (expected.len == 0) {
        try t.expectEqual(null, list.head);
        try t.expectEqual(null, list.tail);
        return;
    }

    var i: usize = 0;
    var next = list.head;
    while (next) |node| {
        try t.expectEqual(expected[i], node.id);
        i += 1;
        next = node.next;
    }
    try t.expectEqual(expected.len, i);

    i = expected.len;
    var prev = list.tail;
    while (prev) |node| {
        i -= 1;
        try t.expectEqual(expected[i], node.id);
        prev = node.prev;
    }
    try t.expectEqual(0, i);
}
