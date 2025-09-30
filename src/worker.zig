const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz.zig");
const metrics = @import("metrics.zig");
const ws = @import("websocket").server;

const Config = httpz.Config;
const Request = httpz.Request;
const Response = httpz.Response;

const BufferPool = @import("buffer.zig").Pool;
const ThreadPool = @import("thread_pool.zig").ThreadPool;

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
        thread_pool: ThreadPool(Self.handleConnection),

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

            var http_conn_pool = try HTTPConnPool.init(allocator, buffer_pool, websocket, 0, config);
            errdefer http_conn_pool.deinit();

            const retain_allocated_bytes_keepalive = config.workers.retain_allocated_bytes orelse 8192;

            var thread_pool = try ThreadPool(Self.handleConnection).init(allocator, .{
                .count = config.threadPoolCount(),
                .backlog = config.thread_pool.backlog orelse 500,
                .buffer_size = config.thread_pool.buffer_size orelse 32_768,
            });
            errdefer {
                thread_pool.stop();
                thread_pool.deinit();
            }

            return .{
                .mut = .{},
                .server = server,
                .config = config,
                .connections = .{},
                .allocator = allocator,
                .websocket = websocket,
                .buffer_pool = buffer_pool,
                .thread_pool = thread_pool,
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
            self.thread_pool.deinit();
            allocator.destroy(self.websocket);

            self.http_conn_pool.deinit();
            self.conn_node_pool.deinit();

            self.buffer_pool.deinit();
            allocator.destroy(self.buffer_pool);
        }

        pub fn listen(self: *Self, listener: posix.socket_t) void {
            var thread_pool = &self.thread_pool;
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
                thread_pool.spawnOne(.{ self, socket, address });
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

        pub fn stop(self: *const Self) void {
            // The HTTP server will stop when the http.Server shutdown the listening socket.
            self.websocket.shutdown();
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

            conn.address = address;
            conn.handover = .unknown;
            conn.stream = .{ .handle = socket };

            var is_keepalive = false;
            while (true) {
                switch (self.handleRequest(conn, is_keepalive, thread_buf) catch .close) {
                    .keepalive => {
                        is_keepalive = true;
                        conn.requestDone(self.retain_allocated_bytes_keepalive, false) catch unreachable;
                    },
                    .close, .unknown => {
                        posix.close(socket);
                        // impossible for this to fail in blocking mode
                        conn.requestDone(self.retain_allocated_bytes_keepalive, false) catch unreachable;
                        self.http_conn_pool.release(conn);
                        return;
                    },
                    .websocket => |ptr| {
                        const hc: *ws.HandlerConn(WSH) = @ptrCast(@alignCast(ptr));
                        // impossible for this to fail in blocking mode
                        conn.requestDone(self.retain_allocated_bytes_keepalive, false) catch unreachable;
                        self.http_conn_pool.release(conn);
                        // blocking read loop
                        // will close the connection
                        self.handleWebSocket(hc) catch |err| {
                            log.err("({f} websocket connection error: {}", .{ address, err });
                        };
                        return;
                    },
                    .disown => {
                        // impossible for this to fail in blocking mode
                        conn.requestDone(self.retain_allocated_bytes_keepalive, false) catch unreachable;
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
                    deadline = timestamp(0) + to.sec;
                }
                try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &to.timeval);
            }

            var is_first = true;
            var reader = stream.reader(&.{}); // Request.State does its own buffering
            while (true) {
                const done = conn.req_state.parse(conn.req_arena.allocator(), reader.interface()) catch |err| {
                    switch (err) {
                        error.ReadFailed => {
                            if (reader.getError()) |e| {
                                switch (e) {
                                    error.WouldBlock => {
                                        if (is_keepalive and is_first) {
                                            metrics.timeoutKeepalive(1);
                                        } else {
                                            metrics.timeoutRequest(1);
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
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                    requestError(conn, err) catch {};
                    posix.close(stream.handle);
                    return .disown;
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
                            deadline = timestamp(0) + to.sec;
                            try posix.setsockopt(stream.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &to.timeval);
                        }
                        is_first = false;
                    }
                } else if (deadline) |dl| {
                    if (timestamp(0) > dl) {
                        metrics.timeoutRequest(1);
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
        // Reference to the httpz.Server. After we've parsed the request we
        // call its handleRequest method.
        server: S,

        // The allocator passed to the server
        allocator: Allocator,

        // KQueue or Epoll, depending on the platform
        loop: Loop,

        // The maximum number of connection we should have at any given time
        // This is specific to this worker (it's a per-worker config).
        max_conn: usize,

        // # of connections this worker is handling.
        len: usize,

        // whether or not the worker is full (len == max_conn)
        full: bool,

        config: *const Config,

        websocket: *ws.Worker(WSH),

        // how many bytes should we retain in a connection's arena allocator
        retain_allocated_bytes: usize,

        // The thread pool that'll actually handle any incoming data. This is what
        // will call server.handleRequest which will eventually call the application
        // action.
        thread_pool: ThreadPool(Self.processData),

        // List of connections waiting on for more data to complete a request
        // (we've gotten some data, but not enough to service the request).
        // This is only ever manipulated directly from the worker thread
        // so doesn't need thread safety.
        request_list: List(Conn(WSH)),

        // Connections which have had at least 1 sucessful request and response
        // and which we are now waiting for another request.
        // This is only ever manipulated directly from the worker thread
        // so doesn't need thread safety.
        keepalive_list: ConcurrentList(Conn(WSH)),

        // Requests currently being processed.
        // The worker thread moves the connnection here, but the thread pool
        // will remove it and put it into handover_list, so this has to be
        // thread safe.
        active_list: ConcurrentList(Conn(WSH)),

        // List of connections which have had a request->response fully handled
        // and are now being handed back to the worker (from the thread pool) to
        // process, essentially telling the worker to handle the conn.handover case.
        // The thread pool inserts into this (so it has to be thread safe for
        // that alone) and the worker thread will process it.
        handover_list: ConcurrentList(Conn(WSH)),

        // A pool of HTTPConn objects. The pool maintains a configured min # of these.
        // An HTTPConn is relatively expensive, since we pre-allocate all types
        // of things (a Request.State and Response.State).
        http_conn_pool: HTTPConnPool,

        // The bulk of this code works with an *HTTPConn, but we wrap it in a
        // Conn(WSH) because an actual connection can either be an HTTPConn or
        // a ws.HandlerConn. So Conn(WSH) is essentially a union between these two.
        // It also has a next/prev, allowing it to be inserted in the above 4
        // lists (requets/keepalive/active/handover).
        // It's lightweight enough that we can use a MemoryPool and don't need
        // the fancier management of something like HTTPConnPool for the HTTPConns
        conn_mem_pool: std.heap.MemoryPool(Conn(WSH)),

        // Request and response processing may require larger buffers than the static
        // buffered of our req/res states. The BufferPool has larger pre-allocated
        // buffers that can be used and, when empty or when a larger buffer is needed,
        // will do dynamic allocation
        buffer_pool: *BufferPool,

        // The timeout, in seconds, that connections in the request phase (in the
        // request_list) will timeout. Entries in request_list are sorted with
        // connections that are closest to timeing out at the head.
        timeout_request: u32,

        // The timeout, in seconds, that connections in the keepalive phase (in the
        // keepalive_list will timeout. Entries in keepalive_list are sorted with
        // connections that are closest to timeing out at the head.
        timeout_keepalive: u32,

        const Self = @This();

        const Loop = switch (loopType()) {
            .kqueue => KQueue(WSH),
            .epoll => EPoll(WSH),
        };

        pub fn init(allocator: Allocator, server: S, config: *const Config) !Self {
            const loop = try Loop.init();
            errdefer loop.deinit();

            const websocket = try allocator.create(ws.Worker(WSH));
            errdefer allocator.destroy(websocket);
            websocket.* = try ws.Worker(WSH).init(allocator, &server._websocket_state);
            errdefer websocket.deinit();

            var buffer_pool = try initializeBufferPool(allocator, config);
            errdefer buffer_pool.deinit();

            var conn_mem_pool = std.heap.MemoryPool(Conn(WSH)).init(allocator);
            errdefer conn_mem_pool.deinit();

            var http_conn_pool = try HTTPConnPool.init(allocator, buffer_pool, websocket, loop.fd, config);
            errdefer http_conn_pool.deinit();

            const thread_pool = try ThreadPool(Self.processData).init(allocator, .{
                .count = config.threadPoolCount(),
                .backlog = config.thread_pool.backlog orelse 500,
                .buffer_size = config.thread_pool.buffer_size orelse 32_768,
            });

            errdefer {
                thread_pool.stop();
                thread_pool.deinit();
            }

            return .{
                .len = 0,
                .full = false,
                .loop = loop,
                .config = config,
                .server = server,
                .allocator = allocator,
                .websocket = websocket,
                .thread_pool = thread_pool,
                .active_list = .{},
                .request_list = .{},
                .handover_list = .{},
                .keepalive_list = .{},
                .buffer_pool = buffer_pool,
                .conn_mem_pool = conn_mem_pool,
                .http_conn_pool = http_conn_pool,
                .max_conn = config.workers.max_conn orelse 8_192,
                .timeout_request = config.timeout.request orelse MAX_TIMEOUT,
                .timeout_keepalive = config.timeout.keepalive orelse MAX_TIMEOUT,
                .retain_allocated_bytes = config.workers.retain_allocated_bytes orelse 8192,
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;

            self.websocket.deinit();
            allocator.destroy(self.websocket);

            self.thread_pool.deinit();

            self.shutdownList(&self.request_list);
            self.shutdownConcurrentList(&self.active_list);
            self.shutdownConcurrentList(&self.handover_list);
            self.shutdownConcurrentList(&self.keepalive_list);

            self.buffer_pool.deinit();
            self.conn_mem_pool.deinit();
            self.http_conn_pool.deinit();
            allocator.destroy(self.buffer_pool);

            self.loop.deinit();
        }

        pub fn stop(self: *Self) void {
            // causes run to break out of its loop
            self.loop.stop();
        }

        pub fn run(self: *Self, listener: posix.fd_t, ready_sem: *std.Thread.Semaphore) void {
            var thread_pool = &self.thread_pool;

            self.loop.start() catch |err| {
                log.err("Failed to start event loop: {}", .{err});
                return;
            };

            // Whether this fails or succeeds we can confidently signal upstream
            // that we're ready enough to be stopped in necessary.
            self.loop.monitorAccept(listener) catch |err| {
                log.err("Failed to add monitor to listening socket: {}", .{err});
                ready_sem.post();
                return;
            };
            ready_sem.post();
            defer self.websocket.shutdown();

            var now = timestamp(0);
            var last_timeout = now;
            while (true) {
                var timeout: ?i32 = 1;
                if (now - last_timeout > 1) {

                    // we don't all prepareToWait more than once per second
                    const had_timeouts, timeout = self.prepareToWait(now);
                    if (had_timeouts and self.full) {
                        self.enableListener(listener);
                    }
                    last_timeout = now;
                }

                var it = self.loop.wait(timeout) catch |err| {
                    log.err("Failed to wait on events: {}", .{err});
                    std.Thread.sleep(std.time.ns_per_s);
                    continue;
                };
                now = timestamp(now);
                var closed_conn = false;

                while (it.next()) |event| {
                    switch (event) {
                        .accept => self.accept(listener, now) catch |err| {
                            log.err("Failed to accept connection: {}", .{err});
                            std.Thread.sleep(std.time.ns_per_ms * 5);
                        },
                        .signal => self.processSignal(&closed_conn),
                        .recv => |conn| switch (conn.protocol) {
                            .http => |http_conn| {
                                switch (http_conn.getState()) {
                                    .request, .keepalive => {},
                                    .active, .handover => {
                                        // we need to finish whatever we're doing
                                        // before we can process more data (i.e. if
                                        // the connection is being upgrade to websocket,
                                        // this will be a websocket message.)
                                        continue;
                                    },
                                }

                                // At this point, the connection is either in
                                // keepalive or request. Either way, we know no
                                // other thread is access the connection, so we
                                // can access _state directly.

                                const stream = http_conn.stream;
                                var reader = stream.reader(&.{}); // Request.State does its own buffering
                                const done = http_conn.req_state.parse(http_conn.req_arena.allocator(), reader.interface()) catch |err| {
                                    // maybe a write fail or something, doesn't matter, we're closing the connection
                                    requestError(http_conn, reader.getError() orelse err) catch {};

                                    // impossible to fail when false is passed
                                    http_conn.requestDone(self.retain_allocated_bytes, false) catch unreachable;
                                    conn.close();
                                    self.disown(conn);
                                    if (self.full) self.enableListener(listener);
                                    continue;
                                };

                                if (done == false) {
                                    self.swapList(conn, .request);
                                    continue;
                                }

                                self.swapList(conn, .active);
                                thread_pool.spawn(.{ self, now, conn });
                            },
                            .websocket => thread_pool.spawn(.{ self, now, conn }),
                        },
                        .shutdown => return,
                    }
                }

                const batch_size = thread_pool.batch_size;
                if (batch_size > 0) {
                    thread_pool.flush(batch_size);
                }

                if (self.full and closed_conn) {
                    self.enableListener(listener);
                }
            }
        }

        fn swapList(self: *Self, conn: *Conn(WSH), new_state: HTTPConn.State) void {
            const http_conn = conn.protocol.http;
            http_conn._mut.lock();
            defer http_conn._mut.unlock();

            switch (http_conn._state) {
                .active => self.active_list.remove(conn),
                .keepalive => self.keepalive_list.remove(conn),
                .request => self.request_list.remove(conn),
                .handover => self.handover_list.remove(conn),
            }

            http_conn.setState(new_state);

            switch (new_state) {
                .active => self.active_list.insert(conn),
                .keepalive => self.keepalive_list.insert(conn),
                .request => self.request_list.insert(conn),
                .handover => self.handover_list.insert(conn),
            }
        }

        fn accept(self: *Self, listener: posix.fd_t, now: u32) !void {
            var len = self.len;
            const max_conn = self.max_conn;

            // Don't try to disconnect keepalive connections when len == max_conn.
            // If you do, you'll get hard-to-reproduce segfaults. Why?
            // This accept function is being called our event loop. If we call
            // self.closeClose(keepalive_list.head) here, there's a chance that
            // the connection which we're closing is in our poll event.
            // And if it is, we'll segfault when we try to do anything with that
            // connection after freeing it here.
            while (true) {
                if (len == max_conn) {
                    self.full = true;
                    self.loop.pauseAccept(listener) catch {};
                    return;
                }
                var address: net.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(net.Address);

                const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK) catch |err| {
                    // On BSD, REUSEPORT_LB means that only 1 worker should get notified
                    // of a connetion. On Linux, however, we only have REUSEPORT, which will
                    // notify all workers. However, we monitor the listener using EPOLLEXCLUSIVE.
                    // This makes it so that "one or more" workers receive it.
                    // In other words, no guarantee that there'll just be 1, but Linux will try
                    // to minimze the count.
                    // In the end, when we call accept, we might get a WouldBlock because
                    // Linux can wake up multiple epoll fds for a single connection.
                    return if (err == error.WouldBlock) {} else err;
                };
                errdefer posix.close(socket);
                metrics.connection();

                const socket_flags = try posix.fcntl(socket, posix.F.GETFL, 0);
                const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
                std.debug.assert(socket_flags & nonblocking == nonblocking);

                const conn = try self.conn_mem_pool.create();
                errdefer self.conn_mem_pool.destroy(conn);

                const http_conn = try self.http_conn_pool.acquire();
                http_conn.request_count = 1;
                http_conn._state = .request;
                http_conn.handover = .unknown;
                http_conn._io_mode = .nonblocking;
                http_conn.address = address;
                http_conn.socket_flags = socket_flags;
                http_conn.stream = .{ .handle = socket };
                http_conn.timeout = now + self.timeout_request;

                self.len += 1;
                conn.* = .{
                    .next = null,
                    .prev = null,
                    .protocol = .{ .http = http_conn },
                };
                self.request_list.insert(conn);
                errdefer {
                    conn.close();
                    self.disown(conn);
                }

                try self.loop.monitorRead(conn);
                len += 1;
            }
        }

        fn processSignal(self: *Self, closed_bool: *bool) void {
            const loop = &self.loop;
            var hl = &self.handover_list;

            // We take the handover list, and then re-initialize it. We do this
            // under lock, so that any thread-pool waiting to handover will either
            // make it into this snapshot, or into the new list.
            // The benefit of this approach is that we don't ahve to hold the
            // handover_list mutex for very long, just long enough to grab the
            // head and re-initialize the inner list.
            // This is ok, because _every_ connetion in the handover list is
            // going to end up in another list (or closed) by the time we're
            // done.
            var c = blk: {
                hl.mut.lock();
                defer hl.mut.unlock();
                const head = hl.inner.head;
                hl.inner = .{};
                break :blk head;
            };

            while (c) |conn| {
                c = conn.next;
                const http_conn = conn.protocol.http;
                switch (http_conn.handover) {
                    .close, .unknown => {
                        closed_bool.* = true;
                        // http handler already closed the socket
                        self.disown(conn);
                    },
                    .disown => {
                        // When res.disown() was called, we immediately removed
                        // the socket from the event loop. This is necessary
                        // because the new owner of the socket might close it
                        // before we get back here.
                        // https://github.com/karlseguin/http.zig/issues/129#issuecomment-3031411404
                        closed_bool.* = true;
                        self.disown(conn);
                    },
                    .websocket => |ptr| {
                        if (comptime WSH == httpz.DummyWebsocketHandler) {
                            std.debug.print("Your httpz handler must have a `WebsocketHandler` declaration. This must be the same type passed to `httpz.upgradeWebsocket`. Closing the connection.\n", .{});
                            closed_bool.* = true;
                            conn.close();
                            self.disown(conn);
                            continue;
                        }

                        self.http_conn_pool.release(http_conn);

                        const hc: *ws.HandlerConn(WSH) = @ptrCast(@alignCast(ptr));
                        conn.protocol = .{ .websocket = hc };

                        loop.switchToOneShot(conn) catch {
                            metrics.internalError();
                            closed_bool.* = true;
                            conn.close();
                            self.disown(conn);
                            continue;
                        };
                    },
                    .keepalive => unreachable,
                }
            }
        }

        // Entry-point of our thread pool. `thread_buf` is a thread-specific buffer
        // that we are free to use as needed.
        // Currently, for an HTTP connection, this is only called when we have a
        // full HTTP request ready to process. For an WebSocket packet, it's called
        // when we have data available - there may or may not be a full message ready
        pub fn processData(self: *Self, now: u32, conn: *Conn(WSH), thread_buf: []u8) void {
            switch (conn.protocol) {
                .http => |http_conn| self.processHTTPData(now, conn, thread_buf, http_conn),
                .websocket => |hc| self.processWebsocketData(conn, thread_buf, hc),
            }
        }

        pub fn processHTTPData(self: *Self, now: u32, conn: *Conn(WSH), thread_buf: []u8, http_conn: *HTTPConn) void {
            metrics.request();
            http_conn.request_count += 1;
            self.server.handleRequest(http_conn, thread_buf);

            var handover = http_conn.handover;
            http_conn.requestDone(self.retain_allocated_bytes, handover == .keepalive or handover == .websocket) catch {
                // This means we failed to put the connection into
                // nonblocking mode. Rare, but safer to clos the connection
                // at this point.
                handover = .close;
            };

            switch (handover) {
                .keepalive => {
                    http_conn.timeout = now + self.timeout_keepalive;
                    self.swapList(conn, .keepalive);
                    return;
                },
                .close, .unknown => {
                    // We _have_ to close the connection here in order to avoid
                    // a bad race condition. By closing it here, we [automatically]
                    // remove the connection from epoll/kqueue, which ensures that
                    // in a single loop through ready-event we won't process both
                    // a signal and a recv message.
                    // If we don't do this here, then you'd get a segfault if
                    // the signal cleared the connetion, and then in recv we'd
                    // try to call conn.getState() after the signal.
                    posix.close(http_conn.stream.handle);
                },
                .websocket, .disown => {},
            }
            self.swapList(conn, .handover);
            self.loop.signal() catch |err| log.err("failed to signal worker: {}", .{err});
        }

        pub fn processWebsocketData(self: *Self, conn: *Conn(WSH), thread_buf: []u8, hc: *ws.HandlerConn(WSH)) void {
            var ws_conn = &hc.conn;
            const success = self.websocket.worker.dataAvailable(hc, thread_buf);
            if (success == false) {
                ws_conn.close(.{ .code = 4997, .reason = "wsz" }) catch {};
                self.websocket.cleanupConn(hc);
            } else if (ws_conn.isClosed()) {
                self.websocket.cleanupConn(hc);
            } else {
                self.loop.rearmRead(conn) catch |err| {
                    log.debug("({f}) failed to add read event monitor: {}", .{ ws_conn.address, err });
                    ws_conn.close(.{ .code = 4998, .reason = "wsz" }) catch {};
                    self.websocket.cleanupConn(hc);
                };
            }
        }

        fn disown(self: *Self, conn: *Conn(WSH)) void {
            const http_conn = conn.protocol.http;
            switch (http_conn._state) {
                .request => self.request_list.remove(conn),
                .handover => self.handover_list.remove(conn),
                .keepalive => self.keepalive_list.remove(conn),
                .active => unreachable,
            }
            self.len -= 1;
            self.http_conn_pool.release(http_conn);
            self.conn_mem_pool.destroy(conn);
        }

        // Enforces timeouts, and returns when the next timeout should be checked.
        fn prepareToWait(self: *Self, now: u32) struct { bool, ?i32 } {
            const request_timed_out, const request_count, const request_timeout = collectTimedOut(&self.request_list, now);

            const keepalive_timed_out, const keepalive_count, const keepalive_timeout = blk: {
                const list = &self.keepalive_list;
                list.mut.lock();
                defer list.mut.unlock();
                break :blk collectTimedOut(&list.inner, now);
            };

            var closed = false;
            if (request_count > 0) {
                closed = true;
                self.closeList(request_timed_out);
                metrics.timeoutRequest(request_count);
            }
            if (keepalive_count > 0) {
                closed = true;
                self.closeList(keepalive_timed_out);
                metrics.timeoutKeepalive(keepalive_count);
            }

            if (request_timeout == null and keepalive_timeout == null) {
                return .{ closed, null };
            }

            const next = @min(request_timeout orelse MAX_TIMEOUT, keepalive_timeout orelse MAX_TIMEOUT);
            if (next < now) {
                // can happen if a socket was just about to timeout when prepareToWait
                // was called
                return .{ closed, 1 };
            }

            return .{ closed, @intCast(next - now) };
        }

        // lists are ordered from soonest to timeout to last, as soon as we find
        // a connection that isn't timed out, we can break;
        // This returns the next timeout.
        fn collectTimedOut(list: *List(Conn(WSH)), now: u32) struct { List(Conn(WSH)), usize, ?u32 } {
            var conn = list.head;
            var count: usize = 0;
            var timed_out: List(Conn(WSH)) = .{};

            while (conn) |c| {
                const timeout = c.protocol.http.timeout;
                if (timeout > now) {
                    list.head = c;
                    return .{ timed_out, count, timeout };
                }
                count += 1;
                conn = c.next;
                timed_out.insert(c);
            }
            list.head = null;
            list.tail = null;
            return .{ timed_out, count, null };
        }

        fn closeList(self: *Self, list: List(Conn(WSH))) void {
            var conn = list.head;
            while (conn) |c| {
                conn = c.next;
                c.close();
                self.disown(c);
            }
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

        fn shutdownConcurrentList(self: *Self, list: *ConcurrentList(Conn(WSH))) void {
            list.mut.lock();
            defer list.mut.unlock();
            self.shutdownList(&list.inner);
        }

        inline fn enableListener(self: *Self, listener: posix.fd_t) void {
            self.full = false;
            self.loop.monitorAccept(listener) catch |err| log.err("Failed to enable monitor to listening socket: {}", .{err});
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
                node.prev = null;
                self.head = node;
                self.tail = node;
            }
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

pub fn ConcurrentList(comptime T: type) type {
    return struct {
        inner: List(T) = .{},
        mut: Thread.Mutex = .{},

        const Self = @This();

        pub fn insert(self: *Self, node: *T) void {
            self.mut.lock();
            defer self.mut.unlock();
            self.inner.insert(node);
        }

        pub fn remove(self: *Self, node: *T) void {
            self.mut.lock();
            defer self.mut.unlock();
            self.inner.remove(node);
        }
    };
}

fn KQueue(comptime WSH: type) type {
    return struct {
        fd: i32,
        change_count: usize,
        change_buffer: [32]Kevent,
        event_list: [128]Kevent,

        const Self = @This();
        const Kevent = posix.Kevent;

        fn init() !Self {
            return .{
                .fd = try posix.kqueue(),
                .change_count = 0,
                .change_buffer = undefined,
                .event_list = undefined,
            };
        }

        fn deinit(self: *const Self) void {
            posix.close(self.fd);
        }

        fn start(self: *Self) !void {
            try self.change(1, 1, posix.system.EVFILT.USER, posix.system.EV.ADD | posix.system.EV.CLEAR, posix.system.NOTE.FFNOP);
            return self.change(2, 2, posix.system.EVFILT.USER, posix.system.EV.ADD | posix.system.EV.ONESHOT, posix.system.NOTE.FFNOP);
        }

        fn stop(self: *Self) void {
            // called from an arbitrary thread, can't use change
            _ = posix.kevent(self.fd, &.{
                .{
                    .ident = 2,
                    .filter = posix.system.EVFILT.USER,
                    .flags = 0,
                    .fflags = posix.system.NOTE.TRIGGER,
                    .data = 0,
                    .udata = 2,
                },
            }, &.{}, null) catch |err| {
                log.err("Failed to send stop signal: {}", .{err});
            };
        }

        fn signal(self: *Self) !void {
            // called from thread pool thread, cant queue these in self.changes
            _ = try posix.kevent(self.fd, &.{.{
                .ident = 1,
                .filter = posix.system.EVFILT.USER,
                .flags = 0,
                .fflags = posix.system.NOTE.TRIGGER,
                .data = 0,
                .udata = 1,
            }}, &.{}, null);
        }

        fn monitorAccept(self: *Self, fd: posix.fd_t) !void {
            try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.ENABLE | posix.system.EV.ADD, 0);
        }

        fn pauseAccept(self: *Self, fd: posix.fd_t) !void {
            try self.change(fd, 0, posix.system.EVFILT.READ, posix.system.EV.DISABLE, 0);
        }

        fn monitorRead(self: *Self, conn: *Conn(WSH)) !void {
            try self.change(conn.getSocket(), @intFromPtr(conn), posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.ENABLE, 0);
        }

        fn rearmRead(self: *Self, conn: *Conn(WSH)) !void {
            // called from the worker thread, can't use change_buffer
            _ = try posix.kevent(self.fd, &.{.{
                .ident = @intCast(conn.getSocket()),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ENABLE,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(conn),
            }}, &.{}, null);
        }

        fn switchToOneShot(self: *Self, conn: *Conn(WSH)) !void {
            // From the Kqueue docs, you'd think you can just re-add the socket with EV.DISPATCH to enable
            // dispatching. But that _does not_ work on MacOS. Removing and Re-adding does.
            const socket = conn.getSocket();
            try self.change(socket, 0, posix.system.EVFILT.READ, posix.system.EV.DELETE, 0);
            try self.change(socket, @intFromPtr(conn), posix.system.EVFILT.READ, posix.system.EV.ADD | posix.system.EV.DISPATCH, 0);
        }

        fn change(self: *Self, fd: posix.fd_t, data: usize, filter: i16, flags: u16, fflags: u16) !void {
            var change_count = self.change_count;
            var change_buffer = &self.change_buffer;

            if (change_count == change_buffer.len) {
                // calling this with an empty event_list will return immediate
                _ = try posix.kevent(self.fd, change_buffer, &.{}, null);
                change_count = 0;
            }
            change_buffer[change_count] = .{
                .ident = @intCast(fd),
                .filter = filter,
                .flags = flags,
                .fflags = fflags,
                .data = 0,
                .udata = data,
            };
            self.change_count = change_count + 1;
        }

        fn wait(self: *Self, timeout_sec: ?i32) !Iterator {
            const event_list = &self.event_list;
            const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .sec = ts, .nsec = 0 } else null;
            const event_count = try posix.kevent(self.fd, self.change_buffer[0..self.change_count], event_list, if (timeout) |ts| &ts else null);
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

            fn next(self: *Iterator) ?Event(WSH) {
                const index = self.index;
                const events = self.events;
                if (index == events.len) {
                    return null;
                }

                const event = &self.events[index];
                self.index = index + 1;

                switch (event.udata) {
                    0 => return .{ .accept = {} },
                    1 => return .{ .signal = {} },
                    2 => return .{ .shutdown = {} },
                    else => |nptr| return .{ .recv = @ptrFromInt(nptr) },
                }
            }
        };
    };
}

fn EPoll(comptime WSH: type) type {
    return struct {
        fd: i32,
        close_fd: i32,
        event_fd: i32,
        event_list: [128]EpollEvent,

        const Self = @This();
        const linux = std.os.linux;
        const EpollEvent = linux.epoll_event;

        fn init() !Self {
            const close_fd = try posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
            errdefer posix.close(close_fd);

            const event_fd = try posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
            errdefer posix.close(event_fd);

            return .{
                .close_fd = close_fd,
                .event_fd = event_fd,
                .event_list = undefined,
                .fd = try posix.epoll_create1(0),
            };
        }

        fn deinit(self: *const Self) void {
            posix.close(self.close_fd);
            posix.close(self.event_fd);
            posix.close(self.fd);
        }

        fn start(self: *Self) !void {
            {
                var event = linux.epoll_event{
                    .data = .{ .ptr = 2 },
                    .events = linux.EPOLL.IN,
                };
                try std.posix.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, self.close_fd, &event);
            }

            {
                var event = linux.epoll_event{
                    .data = .{ .ptr = 1 },
                    .events = linux.EPOLL.IN | linux.EPOLL.ET,
                };
                try std.posix.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, self.event_fd, &event);
            }
        }

        fn stop(self: *Self) void {
            const increment: usize = 1;
            _ = posix.write(self.close_fd, std.mem.asBytes(&increment)) catch |err| {
                log.err("Failed to write to closefd: {}", .{err});
            };
        }

        fn signal(self: *const Self) !void {
            const increment: usize = 1;
            _ = try posix.write(self.event_fd, std.mem.asBytes(&increment));
        }

        fn monitorAccept(self: *Self, fd: posix.fd_t) !void {
            var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.EXCLUSIVE, .data = .{ .ptr = 0 } };
            return std.posix.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, fd, &event);
        }

        fn pauseAccept(self: *Self, fd: posix.fd_t) !void {
            return std.posix.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, fd, null);
        }

        fn monitorRead(self: *Self, conn: *Conn(WSH)) !void {
            var event = linux.epoll_event{
                .data = .{ .ptr = @intFromPtr(conn) },
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            };
            return posix.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, conn.getSocket(), &event);
        }

        fn rearmRead(self: *Self, conn: *Conn(WSH)) !void {
            var event = linux.epoll_event{
                .data = .{ .ptr = @intFromPtr(conn) },
                .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.ONESHOT,
            };
            return posix.epoll_ctl(self.fd, linux.EPOLL.CTL_MOD, conn.getSocket(), &event);
        }

        fn switchToOneShot(self: *Self, conn: *Conn(WSH)) !void {
            return self.rearmRead(conn);
        }

        fn wait(self: *Self, timeout_sec: ?i32) !Iterator {
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

            const event_count = posix.epoll_wait(self.fd, event_list, timeout);
            return .{
                .index = 0,
                .event_fd = self.event_fd,
                .events = event_list[0..event_count],
            };
        }

        const Iterator = struct {
            index: usize,
            event_fd: i32,
            events: []EpollEvent,

            fn next(self: *Iterator) ?Event(WSH) {
                const index = self.index;
                const events = self.events;
                if (index == events.len) {
                    return null;
                }
                self.index = index + 1;

                switch (events[index].data.ptr) {
                    0 => return .{ .accept = {} },
                    1 => return .{ .signal = {} },
                    2 => return .{ .shutdown = {} },
                    else => |nptr| return .{ .recv = @ptrFromInt(nptr) },
                }
            }
        };
    };
}

fn Event(comptime WSH: type) type {
    return union(enum) {
        accept: void,
        signal: void,
        shutdown: void,
        recv: *Conn(WSH),
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

    // Unfortunately, in some special cases, we need to interact with the loop
    // directly from a worker thread. Rather than store a *Loop, which could be
    // misused (not all of the methods are safe to call from the non-worker
    // thread), we store the loop's FD which is more opaque.
    loop: i32,

    fn init(allocator: Allocator, buffer_pool: *BufferPool, websocket: *anyopaque, loop: i32, config: *const Config) !HTTPConnPool {
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
            conn.* = try HTTPConn.init(allocator, buffer_pool, websocket, loop, config);

            conns[i] = conn;
            initialized += 1;
        }

        return .{
            .mut = .{},
            .loop = loop,
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

            conn.* = try HTTPConn.init(self.allocator, self.buffer_pool, self.websocket, self.loop, self.config);
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

        pub fn getSocket(self: Self) posix.fd_t {
            return switch (self.protocol) {
                .http => |hc| hc.stream.handle,
                .websocket => |hc| hc.socket,
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
    // A connection can be in one of four states. This mostly corresponds to which
    // of the worker's lists it is in.
    // - active: There's a thread in the thread pool serving a request
    //
    // - handover: The threadpool is done with the request and wants to transfer
    //             control back to the worker.
    //
    // - request: We have some data, but not enough to service the request. i.e.
    //            we don't have a complete header or missing [part of] the body.
    //            Connections here are subject to the request timeout.
    //
    // - keepalive: Conenction is between requests. We're waiting for the start
    //              of the new request. connections here are suject to the keepalive timeout.
    const State = enum {
        active,
        request,
        handover,
        keepalive,
    };

    pub const Handover = union(enum) {
        disown,
        close,
        unknown,
        keepalive,
        websocket: *anyopaque,
    };

    pub const IOMode = enum {
        blocking,
        nonblocking,
    };

    // can be concurrently accessed, use getState
    _state: State,

    _mut: Thread.Mutex,

    _io_mode: IOMode,

    handover: Handover,

    // unix timestamp (seconds) where this connection should timeout
    timeout: u32,

    // number of requests made on this connection (within a keepalive session)
    request_count: u64,

    stream: net.Stream,
    address: net.Address,
    socket_flags: usize,

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

    // Unfortunately, in some special cases, we need to interact with the loop
    // directly from a worker thread. Rather than store a *Loop, which could be
    // misused (not all of the methods are safe to call from the non-worker
    // thread), we store the loop's FD which is more opaque.
    loop: i32,

    fn init(allocator: Allocator, buffer_pool: *BufferPool, ws_worker: *anyopaque, loop: i32, config: *const Config) !HTTPConn {
        const conn_arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(conn_arena);

        conn_arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer conn_arena.deinit();

        const req_state = try Request.State.init(conn_arena.allocator(), buffer_pool, &config.request);
        const res_state = try Response.State.init(conn_arena.allocator(), &config.response);

        var req_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer req_arena.deinit();

        return .{
            .timeout = 0,
            ._mut = .{},
            ._state = .request,
            .handover = .unknown,
            .stream = undefined,
            .address = undefined,
            .loop = loop,
            .request_count = 0,
            .socket_flags = 0,
            .ws_worker = ws_worker,
            .req_state = req_state,
            .res_state = res_state,
            .req_arena = req_arena,
            .conn_arena = conn_arena,
            ._io_mode = if (comptime httpz.blockingMode()) .blocking else .nonblocking,
        };
    }

    pub fn getState(self: *const HTTPConn) State {
        return @atomicLoad(State, &self._state, .acquire);
    }

    pub fn setState(self: *HTTPConn, state: State) void {
        return @atomicStore(State, &self._state, state, .release);
    }

    pub fn deinit(self: *HTTPConn, allocator: Allocator) void {
        self.req_state.deinit();
        self.req_arena.deinit();
        self.conn_arena.deinit();
        allocator.destroy(self.conn_arena);
    }

    // This method is being called from a worker thread. Be careful what you
    // do here.
    // When a connection is disowned, we need to remove it from the
    // loop, since we aren't responsible for it anymore. However, we
    // can't wait until the normal signal flow to do that, because, for
    // all we know, the new owner of the socket will have closed the
    // connection by then. We need to remove the socket from the loop
    // synchronously when we're asked to disown it (as part of
    // res.disown()).
    pub fn disown(self: *HTTPConn) !void {
        self.handover = .disown;

        if (comptime httpz.blockingMode()) {
            return;
        }

        const loop = self.loop;
        const socket = self.stream.handle;
        switch (comptime loopType()) {
            .kqueue => {
                _ = try posix.kevent(loop, &.{
                    .{
                        .ident = @intCast(socket),
                        .filter = posix.system.EVFILT.READ,
                        .flags = posix.system.EV.DELETE,
                        .fflags = 0,
                        .data = 0,
                        .udata = 0,
                    },
                }, &.{}, null);
            },
            .epoll => {
                return posix.epoll_ctl(loop, std.os.linux.EPOLL.CTL_DEL, socket, null);
            },
        }
    }

    pub fn requestDone(self: *HTTPConn, retain_allocated_bytes: usize, revert_blocking: bool) !void {
        self.req_state.reset();
        self.res_state.reset();
        _ = self.req_arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
        if (revert_blocking) {
            try self.nonblockingMode();
        }
    }

    pub fn writeAll(self: *HTTPConn, data: []const u8) !void {
        const socket = self.stream.handle;

        var i: usize = 0;
        var blocking = false;

        while (i < data.len) {
            const n = posix.write(socket, data[i..]) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.blockingMode();
                    blocking = true;
                    continue;
                },
                else => return err,
            };

            // shouldn't be posssible on a correct posix implementation
            // but let's assert to make sure
            std.debug.assert(n != 0);
            i += n;
        }
    }

    pub fn writeAllIOVec(self: *HTTPConn, vec: [][]const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = self.stream.writer(&buf);
        var i: usize = 0;
        while (true) {
            var n = writer.interface.writeVec(vec[i..]) catch |err| {
                if (writer.err) |socket_err| {
                    switch (socket_err) {
                        error.WouldBlock => {
                            try self.blockingMode();
                            continue;
                        },
                        else => return err,
                    }
                }
                return err;
            };
            while (n >= vec[i].len) {
                n -= vec[i].len;
                i += 1;
                if (i >= vec.len) {
                    return writer.interface.flush();
                }
            }
            vec[i] = vec[i][n..];
        }
    }

    pub fn blockingMode(self: *HTTPConn) !void {
        if (comptime httpz.blockingMode() == true) {
            // When httpz is in blocking mode, than we always keep the socket in
            // blocking mode
            return;
        }
        if (self._io_mode == .blocking) {
            return;
        }
        _ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
        self._io_mode = .blocking;
    }

    pub fn nonblockingMode(self: *HTTPConn) !void {
        if (comptime httpz.blockingMode() == true) {
            // When httpz is in blocking mode, than we always keep the socket in
            // blocking mode
            return;
        }
        if (self._io_mode == .nonblocking) {
            return;
        }
        _ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.socket_flags);
        self._io_mode = .nonblocking;
    }
};

pub fn timestamp(clamp: u32) u32 {
    if (comptime @hasDecl(posix, "CLOCK") == false or posix.CLOCK == void) {
        const value: u32 = @intCast(std.time.timestamp());
        return if (value <= clamp) return clamp + 1 else value;
    }
    const ts = posix.clock_gettime(posix.CLOCK.MONOTONIC) catch unreachable;
    return @intCast(ts.sec);
}

fn initializeBufferPool(allocator: Allocator, config: *const Config) !*BufferPool {
    const large_buffer_count = config.workers.large_buffer_count orelse blk: {
        if (comptime httpz.blockingMode()) {
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
fn requestError(conn: *HTTPConn, err: anyerror) !void {
    const handle = conn.stream.handle;
    switch (err) {
        error.HeaderTooBig => {
            metrics.invalidRequest();
            return writeError(handle, 431, "Request header is too big");
        },
        error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine, error.InvalidContentLength => {
            metrics.invalidRequest();
            return writeError(handle, 400, "Invalid Request");
        },
        error.BodyTooBig => {
            metrics.bodyTooBig();
            return writeError(handle, 413, "Request body is too big");
        },
        error.BrokenPipe, error.ConnectionClosed, error.ConnectionResetByPeer, error.EndOfStream => return,
        else => {
            log.err("server error: {}", .{err});
            metrics.internalError();
            return writeError(handle, 500, "Internal Server Error");
        },
    }
    return err;
}

fn writeError(socket: posix.socket_t, comptime status: u16, comptime msg: []const u8) !void {
    const response = std.fmt.comptimePrint("HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, msg.len, msg });

    var i: usize = 0;
    while (i < msg.len) {
        i += try posix.write(socket, response[i..]);
    }
}

const LoopType = enum {
    kqueue,
    epoll,
};

fn loopType() LoopType {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => .kqueue,
        .linux => .epoll,
        else => unreachable,
    };
}

const t = @import("t.zig");
test "HTTPConnPool" {
    var bp = try BufferPool.init(t.allocator, 2, 64);
    defer bp.deinit();

    var p = try HTTPConnPool.init(t.allocator, &bp, undefined, 0, &.{
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

const TestNode = struct {
    id: i32,
    next: ?*TestNode = null,
    prev: ?*TestNode = null,

    fn alloc(id: i32) *TestNode {
        const tn = t.allocator.create(TestNode) catch unreachable;
        tn.* = .{ .id = id };
        return tn;
    }
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
