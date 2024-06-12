const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz.zig");
const metrics = @import("metrics.zig");
const websocket = httpz.websocket;

const Config = httpz.Config;
const Request = httpz.Request;
const Response = httpz.Response;

const BufferPool = @import("buffer.zig").Pool;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Stream = std.net.Stream;
const NetConn = std.net.StreamServer.Connection;

const net = std.net;
const posix = std.posix;
const log = std.log.scoped(.httpz);

const MAX_TIMEOUT = 2_147_483_647;

// This is a NonBlocking worker. We have N workers, each accepting connections
// and largely working in isolation from each other (the only thing they share
// is the *const config, a reference to the Server and to the Websocket server).
// The bulk of the code in this file exists to support the NonBlocking Worker.
pub fn NonBlocking(comptime S: type) type {
    return struct {
        id: usize,

        server: S,

        // KQueue or Epoll, depending on the platform
        loop: Loop,

        allocator: Allocator,

        // Manager of connections. This includes a list of active connections the
        // worker is responsible for, as well as buffer connections can use to
        // get larger []u8, and a pool of re-usable connection objects to reduce
        // dynamic allocations needed for new requests.
        manager: Manager,

        // the maximum connection a worker should manage, we won't accept more than this
        max_conn: usize,

        config: *const Config,

        signal_pos: usize,
        signal_buf: [64]usize,

        const Self = @This();

        const Loop = switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue,
            .linux => EPoll,
            else => unreachable,
        };

        pub fn init(allocator: Allocator, id: usize, server: S, ws: *websocket.Server, config: *const Config) !Self {
            const loop = try Loop.init();
            errdefer loop.deinit();

            const manager = try Manager.init(allocator, ws, config);
            errdefer manager.deinit();

            return .{
                .id = id,
                .loop = loop,
                .config = config,
                .server = server,
                .manager = manager,
                .signal_pos = 0,
                .signal_buf = undefined,
                .allocator = allocator,
                .max_conn = config.workers.max_conn orelse 512,
            };
        }

        pub fn deinit(self: *Self) void {
            self.manager.deinit();
            self.loop.deinit();
        }

        pub fn run(self: *Self, listener: posix.fd_t, signal: posix.fd_t) void {
            const manager = &self.manager;

            self.loop.monitorAccept(listener) catch |err| {
                log.err("Failed to add monitor to listening socket: {}", .{err});
                return;
            };

            {
                // setup our signal
                // Next we register it in our event loop
                self.loop.monitorSignal(signal) catch |err| {
                    log.err("Failed to add monitor to signal pipe: {}", .{err});
                    return;
                };
            }

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
                        if (self.processSignal(signal, now)) {
                            // signal was closed, we're being told to shutdown
                            return;
                        }
                        continue;
                    }

                    const conn: *align(8) Conn = @ptrFromInt(data);
                    manager.active(conn, now);
                    if (self.handleRequest(conn) == false) {
                        // error in parsing/handling the request, we're closing
                        // this connection
                        manager.close(conn);
                    }
                }
            }
        }

        fn accept(self: *Self, listener: posix.fd_t, now: u32) !void {
            const max_conn = self.max_conn;

            var manager = &self.manager;
            var len = manager.len;

            while (len < max_conn) {
                var address: std.net.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(std.net.Address);

                const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
                    // When available, we use SO_REUSEPORT_LB or SO_REUSEPORT, so WouldBlock
                    // should not be possible in those cases, but if it isn't available
                    // this error should be ignored as it means another thread picked it up.
                    return if (err == error.WouldBlock) {} else err;
                };
                errdefer posix.close(socket);
                metrics.connection();

                // set non blocking
                const flags = (try posix.fcntl(socket, posix.F.GETFL, 0)) | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
                _ = try posix.fcntl(socket, posix.F.SETFL, flags);

                var conn = try manager.new(now);
                conn.socket_flags = flags;
                conn.stream = .{ .handle = socket };
                conn.address = address;

                try self.loop.monitorRead(conn, false);
                len += 1;
            }
        }

        pub fn handleRequest(self: *Self, conn: *Conn) bool {
            const stream = conn.stream;

            const done = conn.req_state.parse(stream) catch |err| {
                requestParseError(conn, err) catch {};
                return false;
            };

            if (done == false) {
                // we need to wait for more data
                self.loop.monitorRead(conn, true) catch |err| {
                    serverError(conn, "unknown event loop error: {}", err) catch {};
                    return false;
                };
                return true;
            }

            metrics.request();
            const server = self.server;
            server._thread_pool.spawn(.{ server, self, conn });
            return true;
        }

        fn processSignal(self: *Self, signal: posix.fd_t, now: u32) bool {
            const s_t = @sizeOf(usize);

            const buflen = @typeInfo(@TypeOf(self.signal_buf)).Array.len * @sizeOf(usize);
            const buf: *[buflen]u8 = @ptrCast(&self.signal_buf);
            const start = self.signal_pos;

            const n = posix.read(signal, buf[start..]) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => 0,
            };

            if (n == 0) {
                // assume closed, indicating a shutdown
                return true;
            }

            const pos = start + n;
            const connections = pos / s_t;

            for (0..connections) |i| {
                const data_start = (i * s_t);
                const data_end = data_start + s_t;
                const conn: *Conn = @ptrFromInt(@as(*usize, @alignCast(@ptrCast(buf[data_start..data_end]))).*);
                self.processHandover(conn, now);
            }

            const partial_len = @mod(pos, s_t);
            const partial_start = pos - partial_len;
            for (0..partial_len) |i| {
                buf[i] = buf[partial_start + i];
            }
            self.signal_pos = partial_len;
            return false;
        }

        fn processHandover(self: *Self, conn: *Conn, now: u32) void {
            switch (conn.handover) {
                .keepalive => {
                    self.loop.monitorRead(conn, true) catch {
                        metrics.internalError();
                        self.manager.close(conn);
                        return;
                    };
                    self.manager.keepalive(conn, now);
                },
                .close => self.manager.close(conn),
                .disown => {
                    if (self.loop.remove(conn)) {
                        self.manager.disown(conn);
                    } else |_| {
                        self.manager.close(conn);
                    }
                },
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
// Should only be created through the worker's ConnPool
pub const Conn = struct {
    // In normal operations, sockets are nonblocking. But since Zig doesn't have
    // async, the applications using httpz have no consistent way to deal with
    // nonblocking/async. So, if they use some of the more advanced features which
    // take over the socket directly, we'll switch to blocking.
    const IOMode = enum {
        blocking,
        nonblocking,
    };

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

    const Handover = enum {
        disown,
        close,
        keepalive,
    };

    io_mode: IOMode,

    state: State,

    handover: Handover,

    // unix timestamp (seconds) where this connection should timeout
    timeout: u32,

    // number of requests made on this connection (within a keepalive session)
    request_count: u64,

    // Socket flags. On connect, we get this in order to change to nonblocking.
    // Since we have it at that point, we might as well store it for the rare cases
    // we need to alter it. In those cases, storing it here allows us to avoid a
    // system call to get the flag again.
    socket_flags: usize,

    // whether or not to close the connection after the resposne is sent
    close: bool,

    stream: std.net.Stream,
    address: std.net.Address,

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

    // Reference to our websocket server
    websocket: *websocket.Server,

    // Workers maintain their active conns in a linked list. The link list is intrusive.
    next: ?*Conn,
    prev: ?*Conn,

    fn init(allocator: Allocator, buffer_pool: *BufferPool, ws: *websocket.Server, io_mode: IOMode, config: *const Config) !Conn {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);

        var req_state = try Request.State.init(allocator, arena, buffer_pool, &config.request);
        errdefer req_state.deinit(allocator);

        var res_state = try Response.State.init(allocator, arena, buffer_pool, &config.response);
        errdefer res_state.deinit(allocator);

        return .{
            .handover = .close,
            .arena = arena,
            .close = false,
            .state = .active,
            .websocket = ws,
            .io_mode = io_mode,
            .stream = undefined,
            .address = undefined,
            .socket_flags = undefined,
            .req_state = req_state,
            .res_state = res_state,
            .next = null,
            .prev = null,
            .timeout = 0,
            .request_count = 0,
        };
    }

    pub fn deinit(self: *Conn, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.req_state.deinit(allocator);
        self.res_state.deinit(allocator);
    }

    // this is the keepalive called by the NonBlocking codepath. It puts the
    // connection back in blocking mode (if it isn't already.)
    pub fn keepaliveAndRestore(self: *Conn, retain_allocated_bytes: usize) !void {
        std.debug.assert(httpz.blockingMode() == false);
        if (self.io_mode == .blocking) {
            _ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.socket_flags);
            self.io_mode = .nonblocking;
        }
        self.keepalive(retain_allocated_bytes);
    }

    // This is called by the above keepaliveAndRestore, but also by the Blocking
    // worker directly.
    pub fn keepalive(self: *Conn, retain_allocated_bytes: usize) void {
        self.req_state.reset();
        self.res_state.reset();
        _ = self.arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
    }

    // getting put back into the pool
    pub fn reset(self: *Conn, retain_allocated_bytes: usize) void {
        self.close = false;
        self.next = null;
        self.prev = null;
        self.stream = undefined;
        self.address = undefined;
        self.io_mode = .nonblocking;
        self.request_count = 0;
        self.req_state.reset();
        self.res_state.reset();
        _ = self.arena.reset(.{ .retain_with_limit = retain_allocated_bytes });
    }

    pub fn blocking(self: *Conn) !void {
        if (comptime httpz.blockingMode() == false) {
            if (self.io_mode == .blocking) return;
            _ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
            self.io_mode = .blocking;
        }
    }
};

const Manager = struct {
    // Double linked list of Conn a worker is actively servicing. An "active"
    // connection is one where we've at least received 1 byte of the request and
    // continues to be "active" until the response is sent.
    active_list: List(Conn),

    // Double linked list of Conn a worker is monitoring. Unlike "active" connections
    // these connections are between requests (which is possible due to keepalive).
    keepalive_list: List(Conn),

    // # of active connections we're managing. This is the length of our list.
    len: usize,

    // A pool of Conn objects. The pool maintains a configured min # of these.
    conn_pool: ConnPool,

    // Request and response processing may require larger buffers than the static
    // buffered of our req/res states. The BufferPool has larger pre-allocated
    // buffers that can be used and, when empty or when a larger buffer is needed,
    // will do dynamic allocation
    buffer_pool: *BufferPool,

    allocator: Allocator,

    timeout_request: u32,
    timeout_keepalive: u32,

    // how many bytes should we retain in our arena allocator between usage (can be 0)
    retain_allocated_bytes: usize,

    // how many bytes should we retain in our arena allocator between keepalive usage
    retain_allocated_bytes_keepalive: usize,

    fn init(allocator: Allocator, ws: *websocket.Server, config: *const Config) !Manager {
        const buffer_pool = try allocator.create(BufferPool);
        errdefer allocator.destroy(buffer_pool);

        buffer_pool.* = try initializeBufferPool(allocator, config);
        errdefer buffer_pool.deinit();

        const conn_pool = try ConnPool.init(allocator, buffer_pool, ws, config);
        errdefer conn_pool.deinit();

        const retain_allocated_bytes = config.workers.retain_allocated_bytes orelse 4096;
        // always retain at least 8192, but if we're configured to retain more
        // between non-keepalive usage, we might as well keep more between
        // keepalive usage.
        const retain_allocated_bytes_keepalive = @max(retain_allocated_bytes, 8192);

        return .{
            .len = 0,
            .active_list = .{},
            .keepalive_list = .{},
            .conn_pool = conn_pool,
            .allocator = allocator,
            .buffer_pool = buffer_pool,
            .retain_allocated_bytes = retain_allocated_bytes,
            .retain_allocated_bytes_keepalive = retain_allocated_bytes_keepalive,
            .timeout_request = config.timeout.request orelse MAX_TIMEOUT,
            .timeout_keepalive = config.timeout.keepalive orelse MAX_TIMEOUT,
        };
    }

    pub fn deinit(self: *Manager) void {
        const allocator = self.allocator;
        var conn_pool = self.conn_pool;

        {
            var conn = self.active_list.head;
            while (conn) |c| {
                c.stream.close();
                conn = c.next;

                c.deinit(allocator);
                conn_pool.mem_pool.destroy(c);
            }
        }

        {
            var conn = self.keepalive_list.head;
            while (conn) |c| {
                c.stream.close();
                conn = c.next;

                c.deinit(allocator);
                conn_pool.mem_pool.destroy(c);
            }
        }

        conn_pool.deinit();
        self.buffer_pool.deinit();
        allocator.destroy(self.buffer_pool);
    }

    fn new(self: *Manager, now: u32) !*Conn {
        const conn = try self.conn_pool.acquire();
        self.active_list.insert(conn);
        conn.request_count = 1;
        conn.timeout = now + self.timeout_request;
        self.len += 1;
        return conn;
    }

    fn active(self: *Manager, conn: *Conn, now: u32) void {
        if (conn.state == .active) return;

        // If we're here, it means the connection is going from a keepalive
        // state to an active state.

        conn.state = .active;
        conn.request_count += 1;
        conn.timeout = now + self.timeout_request;
        self.keepalive_list.remove(conn);
        self.active_list.insert(conn);
    }

    fn keepalive(self: *Manager, conn: *Conn, now: u32) void {
        conn.keepaliveAndRestore(self.retain_allocated_bytes_keepalive) catch {
            self.close(conn);
            return;
        };
        conn.state = .keepalive;
        conn.timeout = now + self.timeout_keepalive;
        self.active_list.remove(conn);
        self.keepalive_list.insert(conn);
    }

    fn close(self: *Manager, conn: *Conn) void {
        conn.stream.close();
        switch (conn.state) {
            .active => self.active_list.remove(conn),
            .keepalive => self.keepalive_list.remove(conn),
        }
        self.conn_pool.release(conn, self.retain_allocated_bytes);
        self.len -= 1;
    }

    fn disown(self: *Manager, conn: *Conn) void {
        switch (conn.state) {
            .active => self.active_list.remove(conn),
            .keepalive => self.keepalive_list.remove(conn),
        }
        self.conn_pool.release(conn, self.retain_allocated_bytes);
        self.len -= 1;
    }

    // Enforces timeouts, and returns when the next timeout should be checked.
    fn prepareToWait(self: *Manager, now: u32) ?i32 {
        const next_active = self.enforceTimeout(self.active_list, now);
        const next_keepalive = self.enforceTimeout(self.keepalive_list, now);

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
    // This returns the next timeout
    fn enforceTimeout(self: *Manager, list: List(Conn), now: u32) TimeoutResult {
        var conn = list.head;
        var count: usize = 0;
        while (conn) |c| {
            const timeout = c.timeout;
            if (timeout > now) {
                return .{ .count = count, .timeout = timeout };
            }
            count += 1;
            self.close(c);
            conn = c.next;
        }
        return .{ .count = count, .timeout = null };
    }
};

// ConnPool is only used in nonblocking mode.
// TODO: Can ConnPool be used in blocking mode too?
const ConnPool = struct {
    conns: []*Conn,
    available: usize,
    allocator: Allocator,
    config: *const Config,
    buffer_pool: *BufferPool,
    websocket: *websocket.Server,
    mem_pool: std.heap.MemoryPool(Conn),

    fn init(allocator: Allocator, buffer_pool: *BufferPool, ws: *websocket.Server, config: *const Config) !ConnPool {
        const min = config.workers.min_conn orelse config.workers.max_conn orelse 32;

        var conns = try allocator.alloc(*Conn, min);
        errdefer allocator.free(conns);

        var mem_pool = std.heap.MemoryPool(Conn).init(allocator);

        var initialized: usize = 0;
        errdefer {
            for (0..initialized) |i| {
                conns[i].deinit(allocator);
                mem_pool.destroy(conns[i]);
            }
        }

        for (0..min) |i| {
            const conn = try mem_pool.create();
            errdefer mem_pool.destroy(conn);
            conn.* = try Conn.init(allocator, buffer_pool, ws, .nonblocking, config);

            conns[i] = conn;
            initialized += 1;
        }

        return .{
            .conns = conns,
            .websocket = ws,
            .config = config,
            .available = min,
            .allocator = allocator,
            .mem_pool = mem_pool,
            .buffer_pool = buffer_pool,
        };
    }

    fn deinit(self: *ConnPool) void {
        const allocator = self.allocator;
        // the rest of the conns are "checked out" and owned by the Manager
        // whichi will free them.
        for (self.conns[0..self.available]) |conn| {
            conn.deinit(allocator);
            self.mem_pool.destroy(conn);
        }
        allocator.free(self.conns);
        self.mem_pool.deinit();
    }

    fn acquire(self: *ConnPool) !*Conn {
        const available = self.available;

        if (available > 0) {
            const index = available - 1;
            self.available = index;
            return self.conns[index];
        }

        const conn = try self.mem_pool.create();
        errdefer self.mem_pool.destroy(conn);
        conn.* = try Conn.init(self.allocator, self.buffer_pool, self.websocket, .nonblocking, self.config);
        return conn;
    }

    fn release(self: *ConnPool, conn: *Conn, retain_allocated_bytes: usize) void {
        const conns = self.conns;
        const available = self.available;
        if (available == conns.len) {
            conn.deinit(self.allocator);
            self.mem_pool.destroy(conn);
            return;
        }

        conn.reset(retain_allocated_bytes);
        conns[available] = conn;
        self.available = available + 1;
    }
};

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
    change_buffer: [16]Kevent,
    event_list: [64]Kevent,

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

    fn monitorAccept(self: *KQueue, fd: c_int) !void {
        try self.change(fd, 0, posix.system.EVFILT_READ, posix.system.EV_ADD);
    }

    fn monitorSignal(self: *KQueue, fd: c_int) !void {
        try self.change(fd, 1, posix.system.EVFILT_READ, posix.system.EV_ADD);
    }

    fn monitorRead(self: *KQueue, conn: *Conn, comptime rearm: bool) !void {
        _ = rearm; // used by epoll
        try self.change(conn.stream.handle, @intFromPtr(conn), posix.system.EVFILT_READ, posix.system.EV_ADD | posix.system.EV_ENABLE | posix.system.EV_DISPATCH);
    }

    fn remove(self: *KQueue, conn: *Conn) !void {
        const fd = conn.stream.handle;
        try self.change(fd, 0, posix.system.EVFILT_READ, posix.system.EV_DELETE);
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
        const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .tv_sec = ts, .tv_nsec = 0 } else null;
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
    event_list: [64]EpollEvent,

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

    fn monitorAccept(self: *EPoll, fd: c_int) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 0 } };
        return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorSignal(self: *EPoll, fd: c_int) !void {
        var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 1 } };
        return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorRead(self: *EPoll, conn: *Conn, comptime rearm: bool) !void {
        const op = if (rearm) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
        var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .ptr = @intFromPtr(conn) } };
        return posix.epoll_ctl(self.q, op, conn.stream.handle, &event);
    }

    fn remove(self: *EPoll, conn: *Conn) !void {
        return posix.epoll_ctl(self.q, linux.EPOLL.CTL_DEL, conn.stream.handle, null);
    }

    fn wait(self: *EPoll, timeout_sec: ?i32) !Iterator {
        const event_list = &self.event_list;
        const event_count = blk: while (true) {
            const rc = linux.syscall6(
                .epoll_pwait2,
                @as(usize, @bitCast(@as(isize, self.q))),
                @intFromPtr(event_list.ptr),
                event_list.len,
                if (timeout_sec) |ts| @intFromPtr(&posix.timespec{ .tv_sec = @intCast(ts), .tv_nsec = 0 }) else 0,
                0,
                @sizeOf(linux.sigset_t),
            );

            // taken from std.os.epoll_waits
            switch (posix.errno(rc)) {
                .SUCCESS => break :blk @as(usize, @intCast(rc)),
                .INTR => continue,
                .BADF => unreachable,
                .FAULT => unreachable,
                .INVAL => unreachable,
                else => unreachable,
            }
        };

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

fn timestamp() u32 {
    if (comptime @hasDecl(std.c, "CLOCK") == false) {
        return @intCast(std.time.timestamp());
    }
    var ts: posix.timespec = undefined;
    posix.clock_gettime(posix.CLOCK.REALTIME, &ts) catch unreachable;
    return @intCast(ts.tv_sec);
}

// This is our Blocking worker. It's very different than NonBlocking and much
// simpler.
pub fn Blocking(comptime S: type) type {
    return struct {
        server: S,
        running: bool,
        config: *const Config,
        allocator: Allocator,
        websocket: *websocket.Server,
        buffer_pool: BufferPool,
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
                    .timeval = std.mem.toBytes(std.posix.timeval{ .tv_sec = @intCast(sec orelse 0), .tv_usec = 0 }),
                };
            }
        };

        const Self = @This();

        pub fn init(allocator: Allocator, server: S, ws: *websocket.Server, config: *const Config) !Self {
            const buffer_pool = try initializeBufferPool(allocator, config);
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
            const retain_allocated_bytes_keepalive = config.workers.retain_allocated_bytes orelse 8192;

            return .{
                .running = true,
                .server = server,
                .config = config,
                .websocket = ws,
                .allocator = allocator,
                .buffer_pool = buffer_pool,
                .timeout_request = timeout_request,
                .timeout_keepalive = timeout_keepalive,
                .timeout_write_error = Timeout.init(5),
                .retain_allocated_bytes_keepalive = retain_allocated_bytes_keepalive,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buffer_pool.deinit();
        }

        pub fn stop(self: *Self) void {
            @atomicStore(bool, &self.running, false, .monotonic);
        }

        pub fn listen(self: *Self, listener: posix.socket_t) void {
            var server = self.server;
            while (true) {
                if (@atomicLoad(bool, &self.running, .monotonic) == false) {
                    return;
                }

                var address: std.net.Address = undefined;
                var address_len: posix.socklen_t = @sizeOf(std.net.Address);
                const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
                    log.err("Failed to accept socket: {}", .{err});
                    continue;
                };
                metrics.connection();
                // calls handleConnection through the server's thread_pool
                server._thread_pool.spawn(.{ self, socket });
            }
        }

        const HandleResult = enum {
            keepalive,
            close,
            disown,
        };

        // Called in a worker thread. `thread_buf` is a thread-specific buffer that
        // we are free to use as needed.
        pub fn handleConnection(self: *Self, socket: posix.socket_t, thread_buf: []u8) void {
            // Tracks whether or not we own `socket`. This almost always stays true
            // but ownership/responsibility can be taken over. For example, if
            // the connection is upgraded to a websocket connect, then the websocket
            // code takes over and this function will just exit without closing
            // the underlying socket.
            var own = true;
            defer if (own) posix.close(socket);

            var conn = Conn.init(self.allocator, &self.buffer_pool, self.websocket, .blocking, self.config) catch |err| {
                log.err("Failed to initialize connection: {}", .{err});
                return;
            };
            defer conn.deinit(self.allocator);

            conn.stream = .{ .handle = socket };

            var is_keepalive = false;
            while (true) {
                switch (self.handleRequest(&conn, is_keepalive, thread_buf) catch .close) {
                    .keepalive => conn.keepalive(self.retain_allocated_bytes_keepalive),
                    .close => break,
                    .disown => {
                        // something (e.g. websocket) has taken over ownership of the socket
                        own = false;
                        break;
                    },
                }
                is_keepalive = true;
            }
        }

        fn handleRequest(self: *const Self, conn: *Conn, is_keepalive: bool, thread_buf: []u8) !Conn.Handover {
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
                            // eitehr way, it's the same code (timeval will just be set to 0 for
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
            self.server.handler(conn, thread_buf);
            return conn.handover;
        }
    };
}

// There's some shared logic between the NonBlocking and Blocking workers.
// Whatever we can de-duplicate, goes here.
fn initializeBufferPool(allocator: Allocator, config: *const Config) !BufferPool {
    const large_buffer_count = config.workers.large_buffer_count orelse blk: {
        if (httpz.blockingMode()) {
            break :blk config.threadPoolCount();
        } else {
            break :blk 16;
        }
    };
    const large_buffer_size = config.workers.large_buffer_size orelse config.request.max_body_size orelse 65536;
    return BufferPool.init(allocator, large_buffer_count, large_buffer_size);
}

// Handles parsing errors. If this returns true, it means Conn has a body ready
// to write. In this case the worker (blocking or nonblocking) will want to send
// the resposne. If it returns false, the worker probably wants to close the connection.
// This function ensures that both Blocking and NonBlocking workers handle these
// errors with the same response
fn requestParseError(conn: *Conn, err: anyerror) !void {
    switch (err) {
        error.HeaderTooBig => {
            metrics.invalidRequest();
            return writeError(conn, 431, "Request header is too big");
        },
        error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
            metrics.invalidRequest();
            return writeError(conn, 400, "Invalid Request");
        },
        error.BrokenPipe, error.ConnectionClosed, error.ConnectionResetByPeer => return,
        else => return serverError(conn, "unknown read/parse error: {}", err),
    }
    log.err("unknown parse error: {}", .{err});
    return err;
}

fn serverError(conn: *Conn, comptime log_fmt: []const u8, err: anyerror) !void {
    log.err("server error: " ++ log_fmt, .{err});
    metrics.internalError();
    return writeError(conn, 500, "Internal Server Error");
}

fn writeError(conn: *Conn, comptime status: u16, comptime msg: []const u8) !void {
    const socket = conn.stream.handle;
    const response = std.fmt.comptimePrint("HTTP/1.1 {d} \r\nConnection: Close\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, msg.len, msg });

    var i: usize = 0;

    const timeout = std.mem.toBytes(std.posix.timeval{ .tv_sec = 5, .tv_usec = 0 });
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
    while (i < response.len) {
        const n = posix.write(socket, response[i..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (conn.io_mode == .blocking) {
                    // We were in blocking mode, which means we reached our timeout
                    // We're done trying to send the response.
                    return error.Timeout;
                }
                try conn.blocking();
                continue;
            },
            else => return err,
        };

        if (n == 0) {
            return error.Closed;
        }

        i += n;
    }
}

const t = @import("t.zig");
test "ConnPool" {
    var bp = try BufferPool.init(t.allocator, 2, 64);
    defer bp.deinit();

    var p = try ConnPool.init(t.allocator, &bp, undefined, &.{
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

    p.release(s2, 4096);
    const s4 = try p.acquire();
    try t.expectEqual(true, s4.req_state.buf.ptr == s2.req_state.buf.ptr);

    p.release(s1, 0);
    p.release(s3, 0);
    p.release(s4, 0);
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
