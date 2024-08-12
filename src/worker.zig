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

// This is our Blocking worker. It's very different than NonBlocking and much
// simpler. (WSH is our websocket handler, and can be void)
pub fn Blocking(comptime S: type, comptime WSH: type) type {
    return struct {
        server: S,
        running: bool,
        config: *const Config,
        allocator: Allocator,
        buffer_pool: *BufferPool,
        http_conn_pool: HTTPConnPool,
        websocket: *ws.Worker(WSH),
        timeout_request: ?Timeout,
        timeout_keepalive: ?Timeout,
        timeout_write_error: Timeout,
        retain_allocated_bytes_keepalive: usize,

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
                .running = true,
                .server = server,
                .config = config,
                .allocator = allocator,
                .http_conn_pool = http_conn_pool,
                .websocket = websocket,
                .buffer_pool = buffer_pool,
                .timeout_request = timeout_request,
                .timeout_keepalive = timeout_keepalive,
                .timeout_write_error = Timeout.init(5),
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
        }

        pub fn listen(self: *Self, listener: posix.socket_t) void {
            var server = self.server;
            while (true) {
                var address: net.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(net.Address);
                const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
                    if (err == error.ConnectionAborted or err == error.SocketNotListening) {
                        return;
                    }
                    log.err("Failed to accept socket: {}", .{err});
                    continue;
                };
                metrics.connection();
                // calls handleConnection through the server's thread_pool
                server._thread_pool.spawn(.{ self, socket, address });
            }
        }

        // Called in a worker thread. `thread_buf` is a thread-specific buffer that
        // we are free to use as needed.
        pub fn handleConnection(self: *Self, socket: posix.socket_t, address: net.Address, thread_buf: []u8) void {
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
                    .close => {
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
            while (true) {
                const done = conn.req_state.parse(stream) catch |err| {
                    if (err == error.WouldBlock) {
                        if (is_keepalive and is_first) {
                            metrics.timeoutKeepalive(1);
                        } else {
                            metrics.timeoutActive(1);
                        }
                        return .close;
                    }
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

        signal: Signal,

        websocket: *ws.Worker(WSH),

        const Self = @This();

        const Loop = switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue,
            .linux => EPoll,
            else => unreachable,
        };

        pub fn init(allocator: Allocator, signals: [2]posix.fd_t, server: S, config: *const Config) !Self {
            const loop = try Loop.init();
            errdefer loop.deinit();

            const websocket = try allocator.create(ws.Worker(WSH));
            errdefer allocator.destroy(websocket);
            websocket.* = try ws.Worker(WSH).init(allocator, &server._websocket_state);
            errdefer websocket.deinit();

            const manager = try ConnManager(WSH).init(allocator, websocket, config);
            errdefer manager.deinit();

            return .{
                .loop = loop,
                .config = config,
                .server = server,
                .manager = manager,
                .websocket = websocket,
                .allocator = allocator,
                .signal = .{ .read_fd = signals[0], .write_fd = signals[1] },
                .max_conn = config.workers.max_conn orelse 512,
            };
        }

        pub fn deinit(self: *Self) void {
            self.websocket.deinit();
            self.allocator.destroy(self.websocket);
            self.manager.deinit();
            self.loop.deinit();
        }

        pub fn run(self: *Self, listener: posix.fd_t) void {
            const manager = &self.manager;

            self.loop.monitorAccept(listener) catch |err| {
                log.err("Failed to add monitor to listening socket: {}", .{err});
                return;
            };

            self.loop.monitorSignal(self.signal.read_fd) catch |err| {
                log.err("Failed to add monitor to signal pipe: {}", .{err});
                return;
            };

            var thread_pool = self.server._thread_pool;

            var now = timestamp();
            while (true) {
                const timeout = manager.prepareToWait(now);
                var it = self.loop.wait(timeout) catch |err| {
                    log.err("Failed to wait on events: {}", .{err});
                    std.time.sleep(std.time.ns_per_s);
                    continue;
                };
                now = timestamp();

                while (it.next()) |data| {
                    if (data == 0) {
                        self.accept(listener, now) catch |err| {
                            log.err("Failed to accept connection: {}", .{err});
                            std.time.sleep(std.time.ns_per_ms * 10);
                        };
                        continue;
                    }

                    if (data == 1) {
                        if (self.processSignal(now) == false) {
                            self.manager.shutdown();
                            self.websocket.shutdown();
                            // signal was closed, we're being told to shutdown
                            return;
                        }
                        continue;
                    }

                    const conn: *Conn(WSH) = @ptrFromInt(data);
                    if (conn.protocol == .http) {
                        manager.active(conn, now);
                    }
                    thread_pool.spawn(.{ self, conn });
                }
            }
        }

        fn accept(self: *Self, listener: posix.fd_t, now: u32) !void {
            var manager = &self.manager;
            const max_conn = self.max_conn;
            while (@atomicLoad(usize, &manager.len, .monotonic) < max_conn) {
                var address: net.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(net.Address);

                const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
                    // When available, we use SO_REUSEPORT_LB or SO_REUSEPORT, so WouldBlock
                    // should not be possible in those cases, but if it isn't available
                    // this error should be ignored as it means another thread picked it up.
                    return if (err == error.WouldBlock) {} else err;
                };
                errdefer posix.close(socket);
                metrics.connection();

                {
                    // socket is _probably_ in NONBLOCKING mode (it inherits
                    // the flag from the listening socket).
                    const flags = try posix.fcntl(socket, posix.F.GETFL, 0);
                    const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
                    if (flags & nonblocking == nonblocking) {
                        // Yup, it's in nonblocking mode. Disable that flag to
                        // put it in blocking mode.
                        _ = try posix.fcntl(socket, posix.F.SETFL, flags & ~nonblocking);
                    }
                }
                const conn = try manager.new(now);
                errdefer manager.close(conn);

                var http_conn = conn.protocol.http;
                http_conn.stream = .{ .handle = socket };
                http_conn.address = address;

                try self.loop.monitorRead(socket, @intFromPtr(conn), false);
            }
        }

        fn processSignal(self: *Self, now: u32) bool {
            // if there's no iterator (not even an empty one), then it means
            // the signal was closed, indicating a shutdown
            var it = self.signal.iterator() orelse return false;
            while (it.next()) |data| {
                const conn: *Conn(WSH) = @ptrFromInt(data);
                switch (conn.protocol) {
                    .http => |http_conn| {
                        switch (http_conn.handover) {
                            .keepalive => {
                                self.loop.monitorRead(http_conn.stream.handle, @intFromPtr(conn), true) catch {
                                    metrics.internalError();
                                    self.manager.close(conn);
                                    continue;
                                };
                                self.manager.keepalive(conn, now);
                            },
                            .close => self.manager.close(conn),
                            .disown => {
                                if (self.loop.remove(http_conn.stream.handle)) {
                                    self.manager.disown(conn);
                                } else |_| {
                                    self.manager.close(conn);
                                }
                            },
                            .websocket => |ptr| {
                                const hc: *ws.HandlerConn(WSH) = @ptrCast(@alignCast(ptr));
                                self.manager.upgrade(conn, hc);
                                self.loop.monitorRead(hc.socket, @intFromPtr(conn), true) catch {
                                    metrics.internalError();
                                    self.manager.close(conn);
                                    continue;
                                };
                            },
                        }
                    },
                    .websocket => {
                        // websocket doesn't use the signaling mechanism to get
                        // the socket back into the event loop after processing
                        // a message.
                        unreachable;
                    },
                }
            }
            return true;
        }

        // Entry-point of our thread pool. `thread_buf` is a thread-specific buffer
        // that we are free to use as needed.
        // Currently, for an HTTP connection, this is only called when we have a
        // full HTTP request ready to process. For an WebSocket packet, it's called
        // when we have data available - there may or may not be a full message ready
        pub fn processData(self: *Self, conn: *Conn(WSH), thread_buf: []u8) void {
            switch (conn.protocol) {
                .http => |http_conn| {
                    const stream = http_conn.stream;

                    const done = http_conn.req_state.parse(stream) catch |err| {
                        requestParseError(http_conn, err) catch {};
                        http_conn.handover = .close;
                        self.signal.write(@intFromPtr(conn)) catch @panic("todo");
                        return;
                    };

                    if (done == false) {
                        // we need to wait for more data
                        self.loop.monitorRead(stream.handle, @intFromPtr(conn), true) catch |err| {
                            serverError(http_conn, "unknown event loop error: {}", err) catch {};
                            http_conn.handover = .close;
                            self.signal.write(@intFromPtr(conn)) catch @panic("todo");
                        };
                        return;
                    }

                    metrics.request();
                    self.server.handleRequest(http_conn, thread_buf);
                    self.signal.write(@intFromPtr(conn)) catch @panic("todo");
                },
                .websocket => |hc| {
                    var ws_conn = &hc.conn;
                    const success = self.websocket.worker.dataAvailable(hc, thread_buf);
                    if (success == false) {
                        ws_conn.close(.{ .code = 4997, .reason = "wsz" }) catch {};
                        self.websocket.cleanupConn(hc);
                    } else if (ws_conn.isClosed()) {
                        self.websocket.cleanupConn(hc);
                    } else {
                        self.loop.monitorRead(hc.socket, @intFromPtr(conn), true) catch |err| {
                            log.debug("({}) failed to add read event monitor: {}", .{ ws_conn.address, err });
                            ws_conn.close(.{ .code = 4998, .reason = "wsz" }) catch {};
                            self.websocket.cleanupConn(hc);
                        };
                    }
                },
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
            index += try posix.write(fd, buf[index..]);
        }
    }

    fn iterator(self: *Signal) ?Iterator {
        const buf = &self.buf;
        const pos = self.pos;

        const n = posix.read(self.read_fd, buf[pos..]) catch |err| switch (err) {
            error.WouldBlock => return .{ .signal = self, .buf = "" },
            else => return null,
        };

        if (n == 0) {
            // closed, server shutdown
            return null;
        }

        return .{ .signal = self, .buf = buf[0 .. pos + n] };
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

        // how many bytes should we retain in our arena allocator between keepalive usage
        retain_allocated_bytes_keepalive: usize,

        const Self = @This();

        fn init(allocator: Allocator, websocket: *anyopaque, config: *const Config) !Self {
            var buffer_pool = try initializeBufferPool(allocator, config);
            errdefer buffer_pool.deinit();

            var conn_mem_pool = std.heap.MemoryPool(Conn(WSH)).init(allocator);
            errdefer conn_mem_pool.deinit();

            const http_conn_pool = try HTTPConnPool.init(allocator, buffer_pool, websocket, config);
            errdefer http_conn_pool.deinit();

            const retain_allocated_bytes = config.workers.retain_allocated_bytes orelse 4096;
            const retain_allocated_bytes_keepalive = @max(retain_allocated_bytes, 8192);

            return .{
                .len = 0,
                .active_list = .{},
                .keepalive_list = .{},
                .allocator = allocator,
                .buffer_pool = buffer_pool,
                .conn_mem_pool = conn_mem_pool,
                .http_conn_pool = http_conn_pool,
                .retain_allocated_bytes_keepalive = retain_allocated_bytes_keepalive,
                .timeout_request = config.timeout.request orelse MAX_TIMEOUT,
                .timeout_keepalive = config.timeout.keepalive orelse MAX_TIMEOUT,
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.buffer_pool.deinit();
            self.conn_mem_pool.deinit();
            self.http_conn_pool.deinit();
            allocator.destroy(self.buffer_pool);
        }

        fn new(self: *Self, now: u32) !*Conn(WSH) {
            const conn = try self.conn_mem_pool.create();
            errdefer self.conn_mem_pool.destroy(conn);

            const http_conn = try self.http_conn_pool.acquire();
            http_conn.state = .active;
            http_conn.request_count = 1;
            http_conn.timeout = now + self.timeout_request;

            self.len += 1;
            conn.* = .{
                .next = null,
                .prev = null,
                .protocol = .{ .http = http_conn },
            };
            self.active_list.insert(conn);
            return conn;
        }

        fn active(self: *Self, conn: *Conn(WSH), now: u32) void {
            var http_conn = conn.protocol.http;
            if (http_conn.state == .active) return;

            // If we're here, it means the connection is going from a keepalive
            // state to an active state.

            http_conn.state = .active;
            http_conn.request_count += 1;
            http_conn.timeout = now + self.timeout_request;

            self.keepalive_list.remove(conn);
            self.active_list.insert(conn);
        }

        fn keepalive(self: *Self, conn: *Conn(WSH), now: u32) void {
            var http_conn = conn.protocol.http;

            http_conn.keepalive(self.retain_allocated_bytes_keepalive);
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
                        // it can be closed (by timeout), and close call disown.
                        .keepalive => self.active_list.remove(conn),
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

        fn shutdown(self: *Self) void {
            self.shutdownList(&self.active_list);
            self.shutdownList(&self.keepalive_list);
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
        len: usize = 0,
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
            self.len += 1;
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
            self.len -= 1;
        }
    };
}

const KQueue = struct {
    q: i32,
    change_count: usize,
    change_buffer: [32]Kevent,
    event_list: [128]Kevent,

    const Kevent = posix.Kevent;

    fn init() !KQueue {
        return .{
            .q = try posix.kqueue(),
            .change_count = 0,
            .change_buffer = undefined,
            .event_list = undefined,
        };
    }

    fn deinit(self: KQueue) void {
        posix.close(self.q);
    }

    fn monitorAccept(self: *KQueue, fd: posix.fd_t) !void {
        try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.ADD);
    }

    fn monitorSignal(self: *KQueue, fd: posix.fd_t) !void {
        try self.change(fd, 1, posix.system.EVFILT.READ, posix.system.EV.ADD);
    }

    fn monitorRead(self: *KQueue, fd: posix.socket_t, data: usize, comptime rearm: bool) !void {
        if (rearm) {
            // for websocket connections, this is called in a thread-pool thread
            // so cannot be queued up - it needs to be immediately picked up
            // since our worker could be in a wait() call.
            const event = Kevent{
                .ident = @intCast(fd),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.DISPATCH,
                .fflags = 0,
                .data = 0,
                .udata = data,
            };
            _ = try posix.kevent(self.q, &.{event}, &[_]Kevent{}, null);
        } else {
            try self.change(fd, data, posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.DISPATCH);
        }
    }

    fn remove(self: *KQueue, fd: posix.fd_t) !void {
        try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.DELETE);
    }

    fn change(self: *KQueue, fd: posix.fd_t, data: usize, filter: i16, flags: u16) !void {
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

    fn wait(self: *KQueue, timeout_sec: ?i32) !Iterator {
        const event_list = &self.event_list;
        const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .sec = ts, .nsec = 0 } else null;
        const event_count = try posix.kevent(self.q, self.change_buffer[0..self.change_count], event_list, if (timeout) |ts| &ts else null);
        self.change_count = 0;

        return .{
            .index = 0,
            .events = event_list[0..event_count],
        };
    }

    const Iterator = struct {
        index: usize,
        events: []Kevent,

        fn next(self: *Iterator) ?usize {
            const index = self.index;
            const events = self.events;
            if (index == events.len) {
                return null;
            }
            self.index = index + 1;
            return self.events[index].udata;
        }
    };
};

const EPoll = struct {
    q: i32,
    event_list: [128]EpollEvent,

    const linux = std.os.linux;
    const EpollEvent = linux.epoll_event;

    fn init() !EPoll {
        return .{
            .event_list = undefined,
            .q = try posix.epoll_create1(0),
        };
    }

    fn deinit(self: EPoll) void {
        posix.close(self.q);
    }

    fn monitorAccept(self: *EPoll, fd: posix.fd_t) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 0 } };
        return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorSignal(self: *EPoll, fd: posix.fd_t) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 1 } };
        return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorRead(self: *EPoll, fd: posix.fd_t, data: usize, comptime rearm: bool) !void {
        const op = if (rearm) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
        var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .ptr = data } };
        return posix.epoll_ctl(self.q, op, fd, &event);
    }

    fn remove(self: *EPoll, fd: posix.fd_t) !void {
        return posix.epoll_ctl(self.q, linux.EPOLL.CTL_DEL, fd, null);
    }

    fn wait(self: *EPoll, timeout_sec: ?i32) !Iterator {
        const event_list = &self.event_list;
        var timeout: i32 = -1;
        if (timeout_sec) |sec| {
            if (sec > 2147483) {
                // max supported timeout by epoll_wait.
                timeout = 2147483647;
            } else {
                timeout = sec * 1000;
            }
        }

        const event_count = posix.epoll_wait(self.q, event_list, timeout);
        return .{
            .index = 0,
            .events = event_list[0..event_count],
        };
    }

    const Iterator = struct {
        index: usize,
        events: []EpollEvent,

        fn next(self: *Iterator) ?usize {
            const index = self.index;
            const events = self.events;
            if (index == events.len) {
                return null;
            }
            self.index = index + 1;
            return self.events[index].data.ptr;
        }
    };
};

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
        const min = config.workers.min_conn orelse config.workers.max_conn orelse 64;

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
                .http => |http_conn| posix.close(http_conn.stream.handle),
                .websocket => |hc| hc.conn.close(.{}) catch {},
            }
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
        keepalive,
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
    arena: *std.heap.ArenaAllocator,

    // This is our ws.Worker(WSH) but the type is erased so that Conn isn't
    // a generic. We don't want Conn to be a generic, because we don't want Response
    // to be generics since that would make using the library unecessarily complex
    // (especially since not everyone cares about websockets).
    ws_worker: *anyopaque,

    fn init(allocator: Allocator, buffer_pool: *BufferPool, ws_worker: *anyopaque, config: *const Config) !HTTPConn {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);

        var req_state = try Request.State.init(allocator, arena, buffer_pool, &config.request);
        errdefer req_state.deinit(allocator);

        var res_state = try Response.State.init(allocator, &config.response);
        errdefer res_state.deinit(allocator);

        return .{
            .arena = arena,
            .close = false,
            .state = .active,
            .handover = .close,
            .stream = undefined,
            .address = undefined,
            .req_state = req_state,
            .res_state = res_state,
            .timeout = 0,
            .request_count = 0,
            .ws_worker = ws_worker,
        };
    }

    pub fn deinit(self: *HTTPConn, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.req_state.deinit(allocator);
        self.res_state.deinit(allocator);
    }

    pub fn keepalive(self: *HTTPConn, retain_allocated_bytes: usize) void {
        self.req_state.reset();
        self.res_state.reset();
        _ = self.arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
    }

    // getting put back into the pool
    pub fn reset(self: *HTTPConn, retain_allocated_bytes: usize) void {
        self.close = false;
        self.handover = .close;
        self.stream = undefined;
        self.address = undefined;
        self.request_count = 0;
        self.req_state.reset();
        self.res_state.reset();
        _ = self.arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
    }
};

pub fn timestamp() u32 {
    if (comptime @hasDecl(posix, "CLOCK") == false or posix.CLOCK == void) {
        return @intCast(std.time.timestamp());
    }
    var ts: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.REALTIME, &ts) catch unreachable;
    return @intCast(ts.tv_sec);
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

    const timeout = std.mem.toBytes(std.posix.timeval{ .tv_sec = 5, .tv_usec = 0 });
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
