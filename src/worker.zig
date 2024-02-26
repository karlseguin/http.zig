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

const os = std.os;
const net = std.net;
const log = std.log.scoped(.httpz);

const MAX_TIMEOUT = 2_147_483_647;

pub fn Worker(comptime S: type) type {
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
            else => @compileError("This branch requires access to kqueue or epoll. Consider using the \"blocking\" branch instead."),
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

        pub fn run(self: *Self, listener: os.fd_t, signal: os.fd_t) void {
            std.os.maybeIgnoreSigpipe();
            const manager = &self.manager;

            self.loop.monitorAccept(listener) catch |err| {
                log.err("Failed to add monitor to listening socket: {}", .{err});
                return;
            };

            {
                // setup our signal

                // First, we make it non blocking
                const flags = os.fcntl(signal, os.F.GETFL, 0)  catch |err| {
                    log.err("Failed to make get signal file flags: {}", .{err});
                    return;
                };

                _ = os.fcntl(signal, os.F.SETFL, flags | @as(u32, @bitCast(std.os.O{ .NONBLOCK = true }))) catch |err| {
                    log.err("Failed to make signal nonblocking: {}", .{err});
                    return;
                };

                // Next we register it in our event loop
                self.loop.monitorSignal(signal) catch |err| {
                    log.err("Failed to add monitor to signal pipe: {}", .{err});
                    return;
                };
            }

            while (true) {
                const timeout = manager.prepareToWait();
                var it = self.loop.wait(timeout) catch |err| {
                    log.err("Failed to wait on events: {}", .{err});
                    std.time.sleep(std.time.ns_per_s);
                    continue;
                };

                while (it.next()) |data| {
                    if (data == 0) {
                        self.accept(listener) catch |err| {
                            log.err("Failed to accept connection: {}", .{err});
                            std.time.sleep(std.time.ns_per_ms * 10);
                        };
                        continue;
                    }

                    if (data == 1) {
                        if (self.processSignal(signal)) {
                            // signal was closed, we're being told to shutdown
                            return;
                        }
                        continue;
                    }

                    const conn: *align(8) Conn = @ptrFromInt(data);
                    manager.active(conn);
                    const result = switch (conn.poll_mode) {
                        .read => self.handleRequest(conn),
                        .write => self.write(conn) catch .close,
                    };
                    self.handleResult(result, conn);
                }
            }
        }

        fn accept(self: *Self, listener: os.fd_t) !void {
            const max_conn = self.max_conn;

            var manager = &self.manager;
            var len = manager.len;

            while (len < max_conn) {
                var address: std.net.Address = undefined;
                var address_len: os.socklen_t = @sizeOf(std.net.Address);

                const socket = os.accept(listener, &address.any, &address_len, os.SOCK.CLOEXEC) catch |err| {
                    // When available, we use SO_REUSEPORT_LB or SO_REUSEPORT, so WouldBlock
                    // should not be possible in those cases, but if it isn't available
                    // this error should be ignored as it means another thread picked it up.
                    return if (err == error.WouldBlock) {} else err;
                };
                errdefer os.close(socket);
                metrics.connection();

                // set non blocking
                const flags = (try os.fcntl(socket, os.F.GETFL, 0)) | @as(u32, @bitCast(std.os.O{ .NONBLOCK = true }));
                _ = try os.fcntl(socket, os.F.SETFL, flags);

                var conn = try manager.new();
                conn.socket_flags = flags;
                conn.stream = .{ .handle = socket };
                conn.address = address;

                try self.loop.monitorRead(conn, false);
                len += 1;
            }
        }

        const HandleResult = enum {
            close,
            keepalive,
            executing,
            wait_for_socket,
        };

        pub fn handleRequest(self: *Self, conn: *Conn) HandleResult {
            const stream = conn.stream;

            const done = conn.req_state.parse(stream) catch |err| {
                switch (err) {
                    error.HeaderTooBig => {
                        metrics.invalidRequest();
                        return self.writeError(conn, 431, "Request header is too big");
                    },
                    error.UnknownMethod, error.InvalidRequestTarget, error.UnknownProtocol, error.UnsupportedProtocol, error.InvalidHeaderLine => {
                        metrics.invalidRequest();
                        return self.writeError(conn, 400, "Invalid Request");
                    },
                    error.BrokenPipe, error.ConnectionClosed, error.ConnectionResetByPeer => {},
                    else => return self.serverError(conn, "unknown read/parse error: {}", err),
                }
                return .close;
            };

            if (done == false) {
                // we need to wait for more data
                self.loop.monitorRead(conn, true) catch |err| {
                    return self.serverError(conn, "unknown event loop error: {}", err);
                };
                return .wait_for_socket;
            }

            metrics.request();
            self.server.handle(self, conn) catch |err| {
                return self.serverError(conn, "handler executor: {}", err);
            };
            return .executing;
        }

        fn processSignal(self: *Self, signal: os.fd_t) bool {
            const s_t = @sizeOf(usize);

            const buflen = @typeInfo(@TypeOf(self.signal_buf)).Array.len * @sizeOf(usize);
            const buf: *[buflen]u8 = @ptrCast(&self.signal_buf);
            const start = self.signal_pos;

            const n = os.read(signal, buf[start..]) catch |err| switch (err) {
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
                self.processHandover(conn);
            }

            const partial_len = @mod(pos, s_t);
            const partial_start = pos - partial_len;
            for (0..partial_len) |i| {
                buf[i] = buf[partial_start + i];
            }
            self.signal_pos = partial_len;
            return false;
        }

        fn processHandover(self: *Self, conn: *Conn) void {
            switch (conn.handover) {
                .write_and_close, .write_and_keepalive => {
                    const result = self.write(conn) catch .close;
                    self.handleResult(result, conn);
                },
                .close => self.manager.close(conn),
                .keepalive => self.handleResult(.keepalive, conn),
                .disown => {
                    if (self.loop.remove(conn)) {
                        self.manager.disown(conn);
                    } else |_| {
                        self.manager.close(conn);
                    }
                },
            }
        }

        fn handleResult(self: *Self, result: HandleResult, conn: *Conn) void {
            var manager = &self.manager;
            switch (result) {
                .keepalive => blk: {
                    self.loop.monitorRead(conn, true) catch {
                        metrics.internalError();
                        manager.close(conn);
                        break :blk;
                    };
                    conn.poll_mode = .read;
                    manager.keepalive(conn);
                },
                .close => manager.close(conn),
                .wait_for_socket, .executing => {},
            }
        }

        fn write(self: *Self, conn: *Conn) !HandleResult {
            const stream = conn.stream;
            var state = &conn.res_state;
            var stage = state.stage;

            var len: usize = 0;
            var buf: []const u8 = undefined;

            if (stage == .header) {
                len = state.header_len;
                buf = state.header_buffer.data;
            } else if (state.body) |b| {
                len = b.len;
                buf = b;
            } else {
                // we can only be here if there's a body
                len = state.body_len;
                buf = state.body_buffer.?.data;
            }

            var pos = state.pos;
            while (pos < len) {
                const n = stream.write(buf[pos..len]) catch |err| {
                    if (err != error.WouldBlock) {
                        return .close;
                    }

                    if (conn.poll_mode != .write) {
                        conn.poll_mode = .write;
                        try self.loop.monitorWrite(conn);
                    }

                    state.pos = pos;
                    state.stage = stage;
                    // we need to wait for more data
                    return .wait_for_socket;
                };

                pos += n;
                if (pos == len) {
                    if (stage == .body) break; // done

                    if (state.body) |b| {
                        buf = b;
                        len = buf.len;
                    } else if (state.body_buffer) |b| {
                        buf = b.data;
                        len = state.body_len;
                    } else {
                        break;
                    }
                    pos = 0;
                    stage = .body;
                }
            }

            if (conn.close) {
                // This connection is going to be closed. Don't waste time putting it
                // back in read mode.
                return .close;
            }

            return .keepalive;
        }

        fn serverError(self: *Self, conn: *Conn, comptime log_fmt: []const u8, err: anyerror) HandleResult {
            log.err("server error: " ++ log_fmt, .{err});
            metrics.internalError();
            return self.writeError(conn, 500, "Internal Server Error");
        }

        fn writeError(self: *Self, conn: *Conn, status: u16, msg: []const u8) HandleResult {
            const aa = conn.arena.allocator();
            var res = Response.init(aa, conn);
            res.status = status;
            res.body = msg;
            res.keepalive = false;

            conn.res_state.prepareForWrite(&res) catch |err| {
                log.err("Failed to prepare error response for writing: {}", .{err});
                return .close;
            };
            return self.write(conn) catch .close;
        }

        pub fn disown(self: *Self, conn: *Conn) void {
            // Called from the handler thread pool.
            if (self.loop.remove(conn)) {
                self.manager.disown(conn);
            } else |_| {
                self.manager.close(conn);
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
    // nonblocking/async. So, if they use some of the more advanced featuresw which
    // take over the socket directly, we'll switch to blocking.
    const IOMode = enum {
        blocking,
        nonblocking,
    };

    // This is largely done to avoid unecessry syscalls. When our response is ready
    // we'll try to send it then and there. Only if we get a WouldBlock do we
    // start monitoring for write/out events from our event loop. When that happens
    // poll_mode becomes .write, and that tells us that we need to revert back to
    // read-listening.
    const PollMode = enum {
        read,
        write,
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
        write_and_close,
        write_and_keepalive,
    };

    io_mode: IOMode,

    poll_mode: PollMode,

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

    fn init(allocator: Allocator, buffer_pool: *BufferPool, ws: *websocket.Server, config: *const Config) !Conn {
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
            .io_mode = .nonblocking,
            .poll_mode = .read,
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

    // being kept connected to a client
    pub fn keepalive(self: *Conn) !void {
        if (self.io_mode == .blocking) {
            _ = try os.fcntl(self.stream.handle, os.F.SETFL, self.socket_flags);
            self.io_mode = .nonblocking;
        }
        self.poll_mode = .read;
        self.req_state.reset();
        self.res_state.reset();
        _ = self.arena.reset(.free_all);
    }

    // getting put back into the pool
    pub fn reset(self: *Conn) void {
        self.close = false;
        self.next = null;
        self.prev = null;
        self.stream = undefined;
        self.address = undefined;
        self.poll_mode = .read;
        self.io_mode = .nonblocking;
        self.req_state.reset();
        self.res_state.reset();
        _ = self.arena.reset(.free_all);
    }

    pub fn blocking(self: *Conn) !void {
        if (self.io_mode == .blocking) return;
        _ = try os.fcntl(self.stream.handle, os.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(std.os.O{ .NONBLOCK = true })));
        self.io_mode = .blocking;
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

    fn init(allocator: Allocator, ws: *websocket.Server, config: *const Config) !Manager {
        const buffer_pool = try allocator.create(BufferPool);
        errdefer allocator.destroy(buffer_pool);

        const large_buffer_count = config.workers.large_buffer_count orelse 16;
        const large_buffer_size = config.workers.large_buffer_size orelse config.request.max_body_size orelse 65536;
        buffer_pool.* = try BufferPool.init(allocator, large_buffer_count, large_buffer_size);
        errdefer buffer_pool.deinit();

        const conn_pool = try ConnPool.init(allocator, buffer_pool, ws, config);

        return .{
            .len = 0,
            .active_list = .{},
            .keepalive_list = .{},
            .conn_pool = conn_pool,
            .allocator = allocator,
            .buffer_pool = buffer_pool,
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

    fn new(self: *Manager) !*Conn {
        const conn = try self.conn_pool.acquire();
        self.active_list.insert(conn);
        conn.request_count = 1;
        conn.timeout = timestamp() + self.timeout_request;
        self.len += 1;
        return conn;
    }

    fn active(self: *Manager, conn: *Conn) void {
        if (conn.state == .active) return;

        // If we're here, it means the connection is going from a keepalive
        // state to an active state.

        conn.state = .active;
        conn.request_count += 1;
        conn.timeout = timestamp() + self.timeout_request;
        self.keepalive_list.remove(conn);
        self.active_list.insert(conn);
    }

    fn keepalive(self: *Manager, conn: *Conn) void {
        conn.keepalive() catch {
            self.close(conn);
            return;
        };
        conn.state = .keepalive;
        conn.timeout = timestamp() + self.timeout_keepalive;
        self.active_list.remove(conn);
        self.keepalive_list.insert(conn);
    }

    fn close(self: *Manager, conn: *Conn) void {
        conn.stream.close();
        switch (conn.state) {
            .active => self.active_list.remove(conn),
            .keepalive => self.keepalive_list.remove(conn),
        }
        self.conn_pool.release(conn);
        self.len -= 1;
    }

    fn disown(self: *Manager, conn: *Conn) void {
        switch (conn.state) {
            .active => self.active_list.remove(conn),
            .keepalive => self.keepalive_list.remove(conn),
        }
        self.conn_pool.release(conn);
        self.len -= 1;
    }

    // Enforces timeouts, and returns when the next timeout should be checked.
    fn prepareToWait(self: *Manager) ?i32 {
        const now = timestamp();
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

    // lists are ordered from soonest to timeout to latest, as soon as we find
    // a connection that isn't timed out, we can break;
    // This returns the next timeout
    fn enforceTimeout(self: *Manager, list: List(Conn), now: u32) TimeoutResult {
        var conn = list.head;
        var count: usize = 0;
        while (conn) |c| {
            const timeout = c.timeout;
            if (timeout > now) {
                return .{.count = count, .timeout = timeout};
            }
            count += 1;
            self.close(c);
            conn = c.next;
        }
        return .{.count = count, .timeout = null};
    }
};

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
            conn.* = try Conn.init(allocator, buffer_pool, ws, config);

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
        conn.* = try Conn.init(self.allocator, self.buffer_pool, self.websocket, self.config);
        return conn;
    }

    fn release(self: *ConnPool, conn: *Conn) void {
        const conns = self.conns;
        const available = self.available;
        if (available == conns.len) {
            conn.deinit(self.allocator);
            self.mem_pool.destroy(conn);
            return;
        }

        conn.reset();
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

    const Kevent = std.os.Kevent;

    fn init() !KQueue {
        return .{
            .q = try std.os.kqueue(),
            .change_count = 0,
            .change_buffer = undefined,
            .event_list = undefined,
        };
    }

    fn deinit(self: KQueue) void {
        std.os.close(self.q);
    }

    fn monitorAccept(self: *KQueue, fd: c_int) !void {
        try self.change(fd, 0, os.system.EVFILT_READ, os.system.EV_ADD);
    }

    fn monitorSignal(self: *KQueue, fd: c_int) !void {
        try self.change(fd, 1, os.system.EVFILT_READ, os.system.EV_ADD);
    }

    fn monitorRead(self: *KQueue, conn: *Conn, comptime rearm: bool) !void {
        _ = rearm; // used by epoll
        try self.change(conn.stream.handle, @intFromPtr(conn), os.system.EVFILT_READ, os.system.EV_ADD | os.system.EV_ENABLE | os.system.EV_DISPATCH);
    }

    fn monitorWrite(self: *KQueue, conn: *Conn) !void {
        try self.change(conn.stream.handle, @intFromPtr(conn), os.system.EVFILT_WRITE, os.system.EV_ADD | os.system.EV_ENABLE | os.system.EV_DISPATCH);
    }

    fn remove(self: *KQueue, conn: *Conn) !void {
        const fd = conn.stream.handle;
        try self.change(fd, 0, os.system.EVFILT_READ, os.system.EV_DELETE);
        try self.change(fd, 0, os.system.EVFILT_WRITE, os.system.EV_DELETE);
    }

    fn change(self: *KQueue, fd: os.fd_t, data: usize, filter: i16, flags: u16) !void {
        var change_count = self.change_count;
        var change_buffer = &self.change_buffer;

        if (change_count == change_buffer.len) {
            // calling this with an empty event_list will return immediate
            _ = try std.os.kevent(self.q, change_buffer, &[_]Kevent{}, null);
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
        const timeout: ?os.timespec = if (timeout_sec) |ts| os.timespec{ .tv_sec = ts, .tv_nsec = 0 } else null;
        const event_count = try std.os.kevent(self.q, self.change_buffer[0..self.change_count], event_list, if (timeout) |ts| &ts else null);
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

    const EpollEvent = std.os.linux.epoll_event;

    fn init() !EPoll {
        return .{
            .event_list = undefined,
            .q = try std.os.epoll_create1(0),
        };
    }

    fn deinit(self: EPoll) void {
        std.os.close(self.q);
    }

    fn monitorAccept(self: *EPoll, fd: c_int) !void {
        var event = os.linux.epoll_event{ .events = os.linux.EPOLL.IN, .data = .{ .ptr = 0 } };
        return std.os.epoll_ctl(self.q, os.linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorSignal(self: *EPoll, fd: c_int) !void {
        var event = os.linux.epoll_event{ .events = os.linux.EPOLL.IN, .data = .{ .ptr = 1 } };
        return std.os.epoll_ctl(self.q, os.linux.EPOLL.CTL_ADD, fd, &event);
    }

    fn monitorRead(self: *EPoll, conn: *Conn, comptime rearm: bool) !void {
        const op = if (rearm) os.linux.EPOLL.CTL_MOD else os.linux.EPOLL.CTL_ADD;
        var event = os.linux.epoll_event{ .events = os.linux.EPOLL.IN | os.linux.EPOLL.ONESHOT, .data = .{ .ptr = @intFromPtr(conn) } };
        return std.os.epoll_ctl(self.q, op, conn.stream.handle, &event);
    }

    // socket always begins with a call to monitorRead(conn, false)
    // so any subsequent call for this socket has to be a modification. Thus,
    // modifyWrite doesn't need a "rearm" flag - it would always be true.
    fn monitorWrite(self: *EPoll, conn: *Conn) !void {
        var event = os.linux.epoll_event{ .events = os.linux.EPOLL.OUT | os.linux.EPOLL.ONESHOT, .data = .{ .ptr = @intFromPtr(conn) } };
        return std.os.epoll_ctl(self.q, os.linux.EPOLL.CTL_MOD, conn.stream.handle, &event);
    }

    fn remove(self: *EPoll, conn: *Conn) !void {
        return std.os.epoll_ctl(self.q, os.linux.EPOLL.CTL_DEL, conn.stream.handle, null);
    }

    fn wait(self: *EPoll, timeout_sec: ?i32) !Iterator {
        const event_list = &self.event_list;
        const event_count = blk: while (true) {
            const rc = os.linux.syscall6(
                .epoll_pwait2,
                @as(usize, @bitCast(@as(isize, self.q))),
                @intFromPtr(event_list.ptr),
                event_list.len,
                if (timeout_sec) |ts| @intFromPtr(&os.timespec{ .tv_sec = @intCast(ts), .tv_nsec = 0 }) else 0,
                0,
                @sizeOf(os.linux.sigset_t),
            );

            // taken from std.os.epoll_waits
             switch (std.os.errno(rc)) {
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
    var ts: os.timespec = undefined;
    os.clock_gettime(os.CLOCK.REALTIME, &ts) catch unreachable;
    return @intCast(ts.tv_sec);
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
