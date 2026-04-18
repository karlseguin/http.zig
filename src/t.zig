// Internal helpers used by this library
// If you're looking for helpers to help you mock/test
// httpz.Request and httpz.Response, checkout testing.zig
// which is exposed as httpz.testing.
const std = @import("std");
const posix_shim = @import("posix_shim.zig");
const io_shim = @import("io_shim.zig");
const httpz = @import("httpz.zig");

const posix = std.posix;
const Allocator = std.mem.Allocator;

const Conn = @import("worker.zig").HTTPConn;
const BufferPool = @import("buffer.zig").Pool;

pub const expectEqual = std.testing.expectEqual;

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub const allocator = std.testing.allocator;
pub var arena = std.heap.ArenaAllocator.init(allocator);

pub fn reset() void {
    _ = arena.reset(.free_all);
}

pub fn getRandom() std.Random.DefaultPrng {
    var seed: u64 = undefined;
    posix_shim.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    return std.Random.DefaultPrng.init(seed);
}

pub const Context = struct {
    // the stream that the server gets
    stream: posix_shim.Stream,

    // the client (e.g. browser stream)
    client: posix_shim.Stream,

    closed: bool = false,

    conn: *Conn,

    arena: *std.heap.ArenaAllocator,

    fake: bool,
    to_read_pos: usize,
    to_read: std.ArrayList(u8),
    _random: ?std.Random.DefaultPrng = null,

    pub fn allocInit(ctx_allocator: Allocator, config_: httpz.Config) Context {
        var pair: [2]posix.socket_t = undefined;
        if (@import("builtin").os.tag == .windows) {
            // create the socket pair manually on Windows because `socketpair` does not exist on Windows
            // use INET instead of LOCAL because LOCAL is an alias for UNIX, which does not exist on Windows
            setupFakeSocketPair(&pair[0], &pair[1]) catch |err| {
                std.debug.print("Failed to setup local client<->server: {}", .{err});
                @panic(@errorName(err));
            };
        } else {
            const rc = std.c.socketpair(posix.AF.LOCAL, posix.SOCK.STREAM, 0, &pair);
            if (rc != 0) {
                @panic("socketpair fail");
            }
        }

        {
            const timeout = std.mem.toBytes(posix.timeval{
                .sec = 0,
                .usec = 20_000,
            });
            posix.setsockopt(pair[0], posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout) catch unreachable;
            posix.setsockopt(pair[0], posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch unreachable;
            posix.setsockopt(pair[1], posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout) catch unreachable;
            posix.setsockopt(pair[1], posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch unreachable;

            // for request.fuzz, which does up to an 8K write. Not sure why this has
            // to be so much more but on linux, even a 10K SNDBUF results in WOULD_BLOCK.
            posix.setsockopt(pair[1], posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 20_000))) catch unreachable;
        }

        const server = posix_shim.Stream{ .handle = pair[0] };
        const client = posix_shim.Stream{ .handle = pair[1] };

        var ctx_arena = ctx_allocator.create(std.heap.ArenaAllocator) catch unreachable;
        ctx_arena.* = std.heap.ArenaAllocator.init(ctx_allocator);

        const aa = ctx_arena.allocator();

        const bp = aa.create(BufferPool) catch unreachable;
        bp.* = BufferPool.init(aa, 2, 256) catch unreachable;

        var config = config_;
        {
            // Various parts of the code using pretty generous defaults. For tests
            // we can use more conservative values.
            const cw = config.workers;
            if (cw.count == null) config.workers.count = 2;
            if (cw.max_conn == null) config.workers.max_conn = 2;
            if (cw.min_conn == null) config.workers.min_conn = 1;
            if (cw.large_buffer_count == null) config.workers.large_buffer_count = 1;
            if (cw.large_buffer_size == null) config.workers.large_buffer_size = 256;
        }

        const req_state = httpz.Request.State.init(aa, bp, &config.request) catch unreachable;
        const res_state = httpz.Response.State.init(aa, &config.response) catch unreachable;

        const conn = aa.create(Conn) catch unreachable;
        conn.* = .{
            ._mut = .init,
            ._state = .request,
            .handover = .close,
            .stream = server,
            .address = posix_shim.Address.initIp4([_]u8{ 127, 0, 0, 200 }, 0),
            .req_state = req_state,
            .res_state = res_state,
            .timeout = 0,
            .loop = 0,
            .request_count = 0,
            .socket_flags = 0,
            .ws_worker = undefined,
            .conn_arena = ctx_arena,
            .req_arena = std.heap.ArenaAllocator.init(aa),
            ._io_mode = if (httpz.blockingMode()) .blocking else .nonblocking,
        };

        return .{ .conn = conn, .arena = ctx_arena, .stream = server, .client = client, .fake = false, .to_read_pos = 0, .to_read = .empty };
    }

    pub fn init(config: httpz.Config) Context {
        return allocInit(allocator, config);
    }

    pub fn deinit(self: *Context) void {
        if (self.closed == false) {
            self.closed = true;
            self.stream.close();
        }
        self.client.close();

        const ctx_allocator = arena.child_allocator;
        self.arena.deinit();
        ctx_allocator.destroy(self.arena);
    }

    fn setupFakeSocketPair(server: *posix.socket_t, client: *posix.socket_t) !void {
        const listener = posix_shim.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
        defer posix_shim.close(listener);

        var address = try posix_shim.Address.parseIp("127.0.0.1", 0);
        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix_shim.bind(listener, &address.any, address.getOsSockLen());
        try posix_shim.listen(listener, 0);

        var len: posix.socklen_t = @sizeOf(posix_shim.Address);
        try posix_shim.getsockname(listener, &address.any, &len);

        var thread = try std.Thread.spawn(.{}, struct {
            fn accept(l: posix.socket_t, server_side: *posix.socket_t) !void {
                server_side.* = try posix_shim.accept(l, null, null, 0);
            }
        }.accept, .{ listener, server });

        client.* = posix_shim.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch unreachable;
        try posix_shim.connect(client.*, &address.any, address.getOsSockLen());
        thread.join();
    }

    // force the server side socket to be closed, which helps our reading-test
    // know that there's no more data.
    pub fn close(self: *Context) void {
        if (self.closed == false) {
            self.closed = true;
            self.stream.close();
        }
    }

    pub fn write(self: *Context, data: []const u8) void {
        if (self.fake) {
            self.to_read.appendSlice(self.arena.allocator(), data) catch unreachable;
        } else {
            var buf: [1024]u8 = undefined;
            var writer = self.client.writer(&buf);
            const w = &writer.interface;
            w.writeAll(data) catch unreachable;
            w.flush() catch unreachable;
        }
    }

    pub fn read(self: Context, a: Allocator) !std.ArrayList(u8) {
        var buf: [1024]u8 = undefined;
        var arr: std.ArrayList(u8) = .empty;

        var reader = self.client.reader(&.{});
        const r = &reader.interface;
        while (true) {
            const n = r.readSliceShort(&buf) catch |err|
                switch (err) {
                    error.ReadFailed => {
                        if (reader.err) |e| {
                            switch (e) {
                                error.WouldBlock => return arr,
                                else => return e,
                            }
                        }
                        return err;
                    },
                };
            if (n == 0) return arr;
            try arr.appendSlice(a, buf[0..n]);
        }
        unreachable;
    }

    pub fn expect(self: Context, expected: []const u8) !void {
        var pos: usize = 0;
        var buf = try allocator.alloc(u8, expected.len);
        defer allocator.free(buf);
        var reader = self.client.reader(&.{});
        const r = &reader.interface;
        while (pos < buf.len) {
            const n = try r.readSliceShort(buf[pos..]);
            if (n == 0) break;
            pos += n;
        }
        try expectString(expected, buf);

        // should have no extra data
        // let's check, with a shor timeout, which could let things slip, but
        // else we slow down fuzz tests too much
        posix.setsockopt(self.client.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(posix.timeval{
            .sec = 0,
            .usec = 1_000,
        })) catch unreachable;

        const n = r.readSliceShort(buf[0..]) catch |err| blk: switch (err) {
            error.ReadFailed => {
                if (reader.err) |e| {
                    switch (e) {
                        error.WouldBlock => break :blk 0,
                        else => @panic(@errorName(e)),
                    }
                }
                @panic(@errorName(err));
            },
        };
        try expectEqual(0, n);

        posix.setsockopt(self.client.handle, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(posix.timeval{
            .sec = 0,
            .usec = 20_000,
        })) catch unreachable;
    }

    fn random(self: *Context) std.Random {
        if (self._random == null) {
            var seed: u64 = undefined;
            posix_shim.getrandom(std.mem.asBytes(&seed)) catch unreachable;
            self._random = std.Random.DefaultPrng.init(seed);
        }
        return self._random.?.random();
    }

    pub fn fakeReader(self: *Context) FakeReader {
        std.debug.assert(self.fake);

        // 0.16 changed `clearRetainingCapacity` to `@memset(items, undefined)`
        // before zeroing the length — the backing memory is clobbered. We
        // must dupe the bytes into arena-owned memory BEFORE clearing, so
        // FakeReader's snapshot survives the clear (and any subsequent
        // writes that reuse the same capacity).
        const buf_copy = self.arena.allocator().dupe(u8, self.to_read.items) catch unreachable;

        const fr = FakeReader{
            .pos = self.to_read_pos,
            .buf = buf_copy,
            .random = self.random(),
        };

        self.to_read_pos = 0;
        self.to_read.clearRetainingCapacity();

        return fr;
    }

    pub fn request(self: Context) httpz.Request {
        return httpz.Request.init(self.conn.req_arena.allocator(), self.conn);
    }

    pub fn response(self: Context) httpz.Response {
        return httpz.Response.init(self.conn.req_arena.allocator(), self.conn);
    }

    pub fn reset(self: Context) void {
        self.to_read_pos = 0;
        self.to_read.clearRetainingCapacity();
        self.conn.reset();
    }

    // We sometimes use a Fake reader when we want to simulate the boundary-less
    // nature of TCP, that is, where a read() might read only a few of the message
    // bytes (because TCP has no concept of a message).
    pub const FakeReader = struct {
        pos: usize,
        buf: []const u8,
        random: std.Random,
        interface: std.Io.Reader =
            .{
                .vtable = &.{
                    .stream = FakeReader.stream,
                },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },

        pub fn read(
            self: *FakeReader,
            buf: []u8,
        ) !usize {
            const data = self.buf[self.pos..];

            if (data.len == 0 or buf.len == 0) {
                return 0;
            }

            // randomly fragment the data
            const to_read = self.random.intRangeAtMost(usize, 1, @min(data.len, buf.len));
            @memcpy(buf[0..to_read], data[0..to_read]);
            self.pos += to_read;
            return to_read;
        }

        fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const r: *FakeReader = @alignCast(@fieldParentPtr("interface", io_reader));
            const data = r.buf[r.pos..];

            if (data.len == 0 or limit == .nothing) {
                return 0;
            }

            // randomly fragment the data
            const to_read = r.random.intRangeAtMost(usize, 1, @min(data.len, limit.toInt() orelse data.len));
            try w.writeAll(data[0..to_read]);
            r.pos += to_read;
            return to_read;
        }
    };
};

pub fn randomString(random: std.Random, a: Allocator, max: usize) []u8 {
    var buf = a.alloc(u8, random.uintAtMost(usize, max) + 1) catch unreachable;
    const valid = "abcdefghijklmnopqrstuvwxyz0123456789-_";
    for (0..buf.len) |i| {
        buf[i] = valid[random.uintAtMost(usize, valid.len - 1)];
    }
    return buf;
}
