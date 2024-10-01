const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz.zig");
const buffer = @import("buffer.zig");

const HTTPConn = @import("worker.zig").HTTPConn;
const Config = @import("config.zig").Config.Response;
const StringKeyValue = @import("key_value.zig").StringKeyValue;

const mem = std.mem;
const Stream = std.net.Stream;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Self = @This();

pub const Response = struct {
    // httpz's wrapper around a stream, the brave can access the underlying .stream
    conn: *HTTPConn,

    // Where in body we're writing to. Used for dynamically writes to body, e.g.
    // via the json() or writer() functions
    pos: usize,

    // The status code to write.
    status: u16,

    // The response headers.
    // Using res.header(NAME, VALUE) is preferred.
    headers: StringKeyValue,

    // The content type. Use header("content-type", value) for a content type
    // which isn't available in the httpz.ContentType enum.
    content_type: ?httpz.ContentType,

    // An arena that will be reset at the end of each request. Can be used
    // internally by this framework. The application is also free to make use of
    // this arena. This is the same arena as request.arena.
    arena: Allocator,

    // whether or not we've already written the response
    written: bool,

    // whether or not we're in chunk transfer mode
    chunked: bool,

    // when false, the Connection: Close header is sent. This should not be set
    // directly, rather set req.keepalive = false.
    keepalive: bool,

    // The body to send. This is set directly, res.body = "Hello World".
    body: []const u8,

    // When the body is written to via the writer API (the json helper wraps
    // the writer api)
    buffer: Buffer,

    pub const State = Self.State;

    const Buffer = struct {
        pos: usize,
        data: []u8,
    };

    // Should not be called directly, but initialized through a pool
    pub fn init(arena: Allocator, conn: *HTTPConn) Response {
        return .{
            .pos = 0,
            .body = "",
            .conn = conn,
            .status = 200,
            .arena = arena,
            .buffer = Buffer{ .pos = 0, .data = "" },
            .chunked = false,
            .written = false,
            .keepalive = true,
            .content_type = null,
            .headers = conn.res_state.headers,
        };
    }

    pub fn disown(self: *Response) void {
        self.written = true;
        self.conn.handover = .disown;
    }

    pub fn json(self: *Response, value: anytype, options: std.json.StringifyOptions) !void {
        try std.json.stringify(value, options, Writer.init(self));
        self.content_type = httpz.ContentType.JSON;
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) void {
        self.headers.add(name, value);
    }

    pub const HeaderOpts = struct {
        dupe_name: bool = false,
        dupe_value: bool = false,
    };

    pub fn headerOpts(self: *Response, name: []const u8, value: []const u8, opts: HeaderOpts) !void {
        const n = if (opts.dupe_name) try self.arena.dupe(u8, name) else name;
        const v = if (opts.dupe_name) try self.arena.dupe(u8, value) else name;
        self.headers.add(n, v);
    }

    pub fn startEventStream(self: *Response, ctx: anytype, comptime handler: fn (@TypeOf(ctx), std.net.Stream) void) !void {
        self.content_type = .EVENTS;
        self.headers.add("Cache-Control", "no-cache");
        self.headers.add("Connection", "keep-alive");

        const conn = self.conn;
        const stream = conn.stream;

        const header_buf = try self.prepareHeader();
        try stream.writeAll(header_buf);

        self.disown();

        const thread = try std.Thread.spawn(.{}, handler, .{ ctx, stream });
        thread.detach();
    }

    pub fn chunk(self: *Response, data: []const u8) !void {
        const stream = self.conn.stream;
        if (!self.chunked) {
            self.chunked = true;
            const header_buf = try self.prepareHeader();
            try stream.writeAll(header_buf);
        }

        // enough for a 1TB chunk
        var buf: [16]u8 = undefined;
        buf[0] = '\r';
        buf[1] = '\n';

        const len = 2 + std.fmt.formatIntBuf(buf[2..], data.len, 16, .upper, .{});
        buf[len] = '\r';
        buf[len + 1] = '\n';

        var vec = [2]std.posix.iovec_const{
            .{ .len = len + 2, .base = &buf },
            .{ .len = data.len, .base = data.ptr },
        };
        try writeAllIOVec(stream.handle, &vec);
    }

    pub fn clearWriter(self: *Response) void {
        self.buffer.pos = 0;
    }

    pub fn writer(self: *Response) Writer.IOWriter {
        return .{ .context = Writer.init(self) };
    }

    pub fn directWriter(self: *Response) Writer {
        return Writer.init(self);
    }

    pub fn write(self: *Response) !void {
        if (self.written) {
            return;
        }
        self.written = true;

        const stream = self.conn.stream;
        if (self.chunked) {
            // If the response was chunked, then we've already written the header
            // the connection is already in blocking mode, but the trailing chunk
            // hasn't bene written yet. We'll write that now, and that's it.
            return stream.writeAll("\r\n0\r\n\r\n");
        }

        const header_buf = try self.prepareHeader();

        const dyn = self.buffer;
        const body = if (dyn.pos > 0) dyn.data[0..dyn.pos] else self.body;

        var vec = [2]std.posix.iovec_const{
            .{ .len = header_buf.len, .base = header_buf.ptr },
            .{ .len = body.len, .base = body.ptr },
        };

        try writeAllIOVec(stream.handle, &vec);
    }

    fn prepareHeader(self: *Response) ![]const u8 {
        const headers = &self.headers;
        const names = headers.keys[0..headers.len];
        const values = headers.values[0..headers.len];

        // 220 gives us enough space to fit:
        // 1 - The status/first line
        // 2 - The Content-Length header or the Transfer-Encoding header.
        // 3 - Our longest supported built-in content type (for a custom content
        //     type, it would have been set via the res.header(...) call, so would
        //     be included in `len)
        var len: usize = 220;
        for (names, values) |name, value| {
            // +4 for the colon, space and trailer
            len += name.len + value.len + 4;
        }

        var buf = try self.arena.alloc(u8, len);

        var pos: usize = "HTTP/1.1 XXX \r\n".len;
        switch (self.status) {
            inline 100...103, 200...208, 226, 300...308, 400...418, 421...426, 428, 429, 431, 451, 500...511 => |status| @memcpy(buf[0..15], std.fmt.comptimePrint("HTTP/1.1 {d} \r\n", .{status})),
            else => |s| {
                const HTTP1_1 = "HTTP/1.1 ";
                const l = HTTP1_1.len;
                @memcpy(buf[0..l], HTTP1_1);
                pos = l + writeInt(buf[l..], @as(u32, s));
                @memcpy(buf[pos..][0..3], " \r\n");
                pos += 3;
            },
        }

        if (self.content_type) |ct| {
            const content_type: ?[]const u8 = switch (ct) {
                .BINARY => "Content-Type: application/octet-stream\r\n",
                .CSS => "Content-Type: text/css; charset=UTF-8\r\n",
                .CSV => "Content-Type: text/csv; charset=UTF-8\r\n",
                .EOT => "Content-Type: application/vnd.ms-fontobject\r\n",
                .EVENTS => "Content-Type: text/event-stream; charset=UTF-8\r\n",
                .GIF => "Content-Type: image/gif\r\n",
                .GZ => "Content-Type: application/gzip\r\n",
                .HTML => "Content-Type: text/html; charset=UTF-8\r\n",
                .ICO => "Content-Type: image/vnd.microsoft.icon\r\n",
                .JPG => "Content-Type: image/jpeg\r\n",
                .JS => "Content-Type: text/javascript; charset=UTF-8\r\n",
                .JSON => "Content-Type: application/json\r\n",
                .OTF => "Content-Type: font/otf\r\n",
                .PDF => "Content-Type: application/pdf\r\n",
                .PNG => "Content-Type: image/png\r\n",
                .SVG => "Content-Type: image/svg+xml\r\n",
                .TAR => "Content-Type: application/x-tar\r\n",
                .TEXT => "Content-Type: text/plain; charset=UTF-8\r\n",
                .TTF => "Content-Type: font/ttf\r\n",
                .WASM => "Content-Type: application/wasm\r\n",
                .WEBP => "Content-Type: image/webp\r\n",
                .WOFF => "Content-Type: font/woff\r\n",
                .WOFF2 => "Content-Type: font/woff2\r\n",
                .XML => "Content-Type: text/xml; charset=UTF-8\r\n",
                .UNKNOWN => null,
            };
            if (content_type) |value| {
                const end = pos + value.len;
                @memcpy(buf[pos..end], value);
                pos = end;
            }
        }

        if (self.keepalive == false) {
            const CLOSE_HEADER = "Connection: Close\r\n";
            const end = pos + CLOSE_HEADER.len;
            @memcpy(buf[pos..end], CLOSE_HEADER);
            pos = end;
        }

        for (names, values) |name, value| {
            {
                // write the name
                const end = pos + name.len;
                @memcpy(buf[pos..end], name);
                pos = end;
                buf[pos] = ':';
                buf[pos + 1] = ' ';
                pos += 2;
            }

            {
                // write the value + trailer
                const end = pos + value.len;
                @memcpy(buf[pos..end], value);
                pos = end;
                buf[pos] = '\r';
                buf[pos + 1] = '\n';
                pos += 2;
            }
        }

        const buffer_pos = self.buffer.pos;
        const body_len = if (buffer_pos > 0) buffer_pos else self.body.len;
        if (body_len > 0) {
            const CONTENT_LENGTH = "Content-Length: ";
            var end = pos + CONTENT_LENGTH.len;
            @memcpy(buf[pos..end], CONTENT_LENGTH);
            pos = end;

            pos += writeInt(buf[pos..], @intCast(body_len));
            end = pos + 4;
            @memcpy(buf[pos..end], "\r\n\r\n");
            return buf[0..end];
        }

        const fin = blk: {
            // For chunked, we end with a single \r\n because the call to res.chunk()
            // prepends a \r\n. Hence,for the first chunk, we'll have the correct \r\n\r\n
            if (self.chunked) break :blk "Transfer-Encoding: chunked\r\n";
            if (self.content_type == .EVENTS) break :blk "\r\n";
            break :blk "Content-Length: 0\r\n\r\n";
        };

        const end = pos + fin.len;
        @memcpy(buf[pos..end], fin);
        return buf[0..end];
    }

    // std.io.Writer.
    pub const Writer = struct {
        res: *Response,

        pub const Error = Allocator.Error;
        pub const IOWriter = std.io.Writer(Writer, error{OutOfMemory}, Writer.write);

        fn init(res: *Response) Writer {
            return .{ .res = res };
        }

        pub fn truncate(self: Writer, n: usize) void {
            const buf = &self.res.buffer;
            const pos = buf.pos;
            const to_truncate = if (pos > n) n else pos;
            buf.pos = pos - to_truncate;
        }

        pub fn writeByte(self: Writer, b: u8) !void {
            var buf = try self.ensureSpace(1);
            const pos = buf.pos;
            buf.data[pos] = b;
            buf.pos = pos + 1;
        }

        pub fn writeByteNTimes(self: Writer, b: u8, n: usize) !void {
            var buf = try self.ensureSpace(n);
            const pos = buf.pos;
            var data = buf.data;
            for (pos..pos + n) |i| {
                data[i] = b;
            }
            buf.pos = pos + n;
        }

        pub fn writeBytesNTimes(self: Writer, bytes: []const u8, n: usize) !void {
            const l = bytes.len * n;
            var buf = try self.ensureSpace(l);

            var pos = buf.pos;
            var data = buf.data;

            for (0..n) |_| {
                const end_pos = pos + bytes.len;
                @memcpy(data[pos..end_pos], bytes);
                pos = end_pos;
            }
            buf.pos = l;
        }

        pub fn writeAll(self: Writer, data: []const u8) !void {
            var buf = try self.ensureSpace(data.len);
            const pos = buf.pos;
            const end_pos = pos + data.len;
            @memcpy(buf.data[pos..end_pos], data);
            buf.pos = end_pos;
        }

        pub fn write(self: Writer, data: []const u8) Allocator.Error!usize {
            try self.writeAll(data);
            return data.len;
        }

        pub fn print(self: Writer, comptime format: []const u8, args: anytype) Allocator.Error!void {
            return std.fmt.format(self, format, args);
        }

        fn ensureSpace(self: Writer, n: usize) !*Buffer {
            const res = self.res;
            var buf = &res.buffer;
            const pos = buf.pos;
            const required_capacity = pos + n;

            const data = buf.data;
            if (data.len > required_capacity) {
                return buf;
            }

            var new_capacity = data.len;
            while (true) {
                new_capacity +|= new_capacity / 2 + 8;
                if (new_capacity >= required_capacity) break;
            }

            const new = try res.arena.alloc(u8, new_capacity);
            if (pos > 0) {
                @memcpy(new[0..pos], data[0..pos]);
                // reasonable chance that our last allocation was buf, so we
                // might as well try freeing it (ArenaAllocator's free is a noop
                // unless you're frenig the last allocation)
                res.arena.free(data);
            }
            buf.data = new;
            return buf;
        }
    };
};

fn writeAllIOVec(socket: std.posix.socket_t, vec: []std.posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = try std.posix.writev(socket, vec[i..]);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }
        vec[i].base += n;
        vec[i].len -= n;
    }
}

// All the upfront memory allocation that we can do. Gets re-used from request
// to request.
pub const State = struct {
    // re-used from request to request, exposed in via res.header(name, value
    headers: StringKeyValue,

    pub fn init(allocator: Allocator, config: *const Config) !Response.State {
        var headers = try StringKeyValue.init(allocator, config.max_header_count orelse 16);
        errdefer headers.deinit(allocator);

        return .{
            .headers = headers,
        };
    }

    pub fn deinit(self: *State, allocator: Allocator) void {
        self.headers.deinit(allocator);
    }

    pub fn reset(self: *State) void {
        self.headers.reset();
    }
};

fn writeInt(into: []u8, value: u32) usize {
    const small_strings = "00010203040506070809" ++
        "10111213141516171819" ++
        "20212223242526272829" ++
        "30313233343536373839" ++
        "40414243444546474849" ++
        "50515253545556575859" ++
        "60616263646566676869" ++
        "70717273747576777879" ++
        "80818283848586878889" ++
        "90919293949596979899";

    var v = value;
    var i: usize = 10;
    var buf: [10]u8 = undefined;
    while (v >= 100) {
        const digits = v % 100 * 2;
        v /= 100;
        i -= 2;
        buf[i + 1] = small_strings[digits + 1];
        buf[i] = small_strings[digits];
    }

    {
        const digits = v * 2;
        i -= 1;
        buf[i] = small_strings[digits + 1];
        if (v >= 10) {
            i -= 1;
            buf[i] = small_strings[digits];
        }
    }

    const l = buf.len - i;
    @memcpy(into[0..l], buf[i..]);
    return l;
}

const t = @import("t.zig");
test "writeInt" {
    var buf: [10]u8 = undefined;
    var tst: [10]u8 = undefined;
    for (0..100_009) |i| {
        const expected_len = std.fmt.formatIntBuf(tst[0..], i, 10, .lower, .{});
        const l = writeInt(&buf, @intCast(i));
        try t.expectString(tst[0..expected_len], buf[0..l]);
    }
}

test "response: write" {
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    {
        // no body
        var res = ctx.response();
        res.status = 401;
        try res.write();
        try ctx.expect("HTTP/1.1 401 \r\nContent-Length: 0\r\n\r\n");
    }

    {
        // body
        var res = ctx.response();
        res.status = 200;
        res.body = "hello";
        try res.write();
        try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 5\r\n\r\nhello");
    }
}

test "response: content_type" {
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    var res = ctx.response();
    res.content_type = httpz.ContentType.WEBP;
    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Type: image/webp\r\nContent-Length: 0\r\n\r\n");
}

test "response: write header_buffer_size" {
    {
        // no header or bodys
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        res.status = 792;
        try res.write();
        try ctx.expect("HTTP/1.1 792 \r\nContent-Length: 0\r\n\r\n");
    }

    {
        // no body
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        res.status = 401;
        res.header("a-header", "a-value");
        res.header("b-hdr", "b-val");
        res.header("c-header11", "cv");
        try res.write();
        try ctx.expect("HTTP/1.1 401 \r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 0\r\n\r\n");
    }

    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        res.status = 8;
        res.header("a-header", "a-value");
        res.header("b-hdr", "b-val");
        res.header("c-header11", "cv");
        res.body = "hello world!";
        try res.write();
        try ctx.expect("HTTP/1.1 8 \r\na-header: a-value\r\nb-hdr: b-val\r\nc-header11: cv\r\nContent-Length: 12\r\n\r\nhello world!");
    }
}

test "response: header" {
    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        res.header("Key1", "Value1");
        try res.write();
        try ctx.expect("HTTP/1.1 200 \r\nKey1: Value1\r\nContent-Length: 0\r\n\r\n");
    }

    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        const k = try t.allocator.dupe(u8, "Key2");
        const v = try t.allocator.dupe(u8, "Value2");
        try res.headerOpts(k, v, .{ .dupe_name = true, .dupe_value = true });
        t.allocator.free(k);
        t.allocator.free(v);
        try res.write();
        try ctx.expect("HTTP/1.1 200 \r\nKey2: Value2\r\nContent-Length: 0\r\n\r\n");
    }
}

test "response: direct writer" {
    defer t.reset();
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    var res = ctx.response();

    var writer = res.directWriter();
    writer.truncate(1);
    try writer.writeByte('[');
    writer.truncate(4);
    try writer.writeByte('[');
    try writer.writeAll("12345");
    writer.truncate(2);
    try writer.writeByte(',');
    try writer.writeAll("456");
    try writer.writeByte(',');
    writer.truncate(1);
    try writer.writeByte(']');

    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 9\r\n\r\n[123,456]");
}

// this used to crash
test "response: multiple writers" {
    defer t.reset();
    var ctx = t.Context.init(.{});
    defer ctx.deinit();
    var res = ctx.response();
    {
        var w = res.writer();
        try w.writeAll("a" ** 5000);
    }
    {
        var w = res.writer();
        try w.writeAll("z" ** 10);
    }
    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 5010\r\n\r\n" ++ ("a" ** 5000) ++ ("z" ** 10));
}

test "response: written" {
    defer t.reset();
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    var res = ctx.response();

    res.body = "abc";
    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 3\r\n\r\nabc");

    // write again, without a res.reset, nothing gets written
    res.body = "yo!";
    try res.write();
    try ctx.expect("");
}

test "response: clearWriter" {
    defer t.reset();
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    var res = ctx.response();
    var writer = res.writer();

    try writer.writeAll("abc");
    res.clearWriter();
    try writer.writeAll("123");

    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nContent-Length: 3\r\n\r\n123");
}
