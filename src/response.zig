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
    buffer: std.ArrayListUnmanaged(u8),

    pub const Writer = std.ArrayListUnmanaged(u8).Writer;

    pub const State = Self.State;

    // Should not be called directly, but initialized through a pool
    pub fn init(arena: Allocator, conn: *HTTPConn) Response {
        return .{
            .pos = 0,
            .body = "",
            .conn = conn,
            .status = 200,
            .arena = arena,
            .chunked = false,
            .written = false,
            .keepalive = true,
            .content_type = null,
            .headers = conn.res_state.headers,
            .buffer = .{},
        };
    }

    pub fn disown(self: *Response) !void {
        self.written = true;
        return self.conn.disown();
    }

    pub fn json(self: *Response, value: anytype, options: std.json.StringifyOptions) !void {
        try std.json.stringify(value, options, self.buffer.writer(self.arena));
        self.content_type = httpz.ContentType.JSON;
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) void {
        self.headers.add(name, value);
    }

    pub fn setStatus(self: *Response, status: std.http.Status) void {
        self.status = @intFromEnum(status);
    }

    pub fn setCookie(self: *Response, name: []const u8, value: []const u8, opts: CookieOpts) !void {
        const serialized = try serializeCookie(self.arena, name, value, &opts);
        self.header("Set-Cookie", serialized);
    }

    pub const HeaderOpts = struct {
        dupe_name: bool = false,
        dupe_value: bool = false,
    };

    pub fn headerOpts(self: *Response, name: []const u8, value: []const u8, opts: HeaderOpts) !void {
        const n = if (opts.dupe_name) try self.arena.dupe(u8, name) else name;
        const v = if (opts.dupe_value) try self.arena.dupe(u8, value) else value;
        self.headers.add(n, v);
    }

    pub fn startEventStream(self: *Response, ctx: anytype, comptime handler: fn (@TypeOf(ctx), std.net.Stream) void) !void {
        self.content_type = .EVENTS;
        self.headers.add("Cache-Control", "no-cache");
        self.headers.add("Connection", "keep-alive");

        const conn = self.conn;
        const stream = conn.stream;

        // caller probably expects this to be in blocking mode
        try conn.blockingMode();
        const header_buf = try self.prepareHeader();
        try stream.writeAll(header_buf);

        try self.disown();

        const thread = try std.Thread.spawn(.{}, handler, .{ ctx, stream });
        thread.detach();
    }

    pub fn startEventStreamSync(self: *Response) !std.net.Stream {
        self.content_type = .EVENTS;
        self.headers.add("Cache-Control", "no-cache");
        self.headers.add("Connection", "keep-alive");

        const conn = self.conn;
        const stream = conn.stream;

        // just keep it in non-blocking mode and return the stream
        const header_buf = try self.prepareHeader();
        try stream.writeAll(header_buf);

        try self.disown();
        return stream;
    }

    pub fn chunk(self: *Response, data: []const u8) !void {
        const conn = self.conn;
        if (!self.chunked) {
            self.chunked = true;
            const header_buf = try self.prepareHeader();
            try conn.writeAll(header_buf);
        }

        // enough for a 1TB chunk
        var buf: [16]u8 = undefined;
        var w: std.io.Writer = .fixed(&buf);
        try w.writeByte('\r');
        try w.writeByte('\n');
        try w.printInt(data.len, 16, .upper, .{});
        try w.writeByte('\r');
        try w.writeByte('\n');

        var vec = [2]std.posix.iovec_const{
            .{ .len = w.end, .base = &buf },
            .{ .len = data.len, .base = data.ptr },
        };
        try conn.writeAllIOVec(&vec);
    }

    pub fn clearWriter(self: *Response) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn writer(self: *Response) Writer {
        return self.buffer.writer(self.arena);
    }

    pub fn write(self: *Response) !void {
        if (self.written) {
            return;
        }
        self.written = true;

        const conn = self.conn;
        if (self.chunked) {
            // If the response was chunked, then we've already written the header
            // the connection is already in blocking mode, but the trailing chunk
            // hasn't bene written yet. We'll write that now, and that's it.
            return conn.writeAll("\r\n0\r\n\r\n");
        }

        const header_buf = try self.prepareHeader();

        const dyn = self.buffer.items;
        const body = if (dyn.len > 0) dyn else self.body;

        var vec = [2]std.posix.iovec_const{
            .{ .len = header_buf.len, .base = header_buf.ptr },
            .{ .len = body.len, .base = body.ptr },
        };
        return conn.writeAllIOVec(&vec);
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
                .JSON => "Content-Type: application/json; charset=UTF-8\r\n",
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

        const buffer_pos = self.buffer.items.len;
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
            if (headers.has("Content-Length")) break :blk "\r\n";
            break :blk "Content-Length: 0\r\n\r\n";
        };

        const end = pos + fin.len;
        @memcpy(buf[pos..end], fin);
        return buf[0..end];
    }
};

pub const CookieOpts = struct {
    // by not using optional, we can get the len without the if check
    path: []const u8 = "",
    domain: []const u8 = "",
    max_age: ?i32 = null,
    secure: bool = false,
    http_only: bool = false,
    partitioned: bool = false,
    same_site: ?SameSite = null,

    pub const SameSite = enum {
        lax,
        strict,
        none,
    };
};

// we expect arena to be an ArenaAllocator
pub fn serializeCookie(arena: Allocator, name: []const u8, value: []const u8, cookie: *const CookieOpts) ![]u8 {
    // Golang uses 110 as a "typical length of cookie attributes"
    const path = cookie.path;
    const domain = cookie.domain;

    const estimated_len = name.len + value.len + path.len + domain.len + 110;
    var buf = std.ArrayListUnmanaged(u8){};

    try buf.ensureTotalCapacity(arena, estimated_len);
    buf.appendSliceAssumeCapacity(name);
    buf.appendAssumeCapacity('=');

    if (std.mem.indexOfAny(u8, value, ", ") != null) {
        buf.appendAssumeCapacity('"');
        buf.appendSliceAssumeCapacity(value);
        buf.appendAssumeCapacity('"');
    } else {
        buf.appendSliceAssumeCapacity(value);
    }

    if (path.len != 0) {
        buf.appendSliceAssumeCapacity("; Path=");
        buf.appendSliceAssumeCapacity(path);
    }

    if (domain.len != 0) {
        buf.appendSliceAssumeCapacity("; Domain=");
        buf.appendSliceAssumeCapacity(domain);
    }

    if (cookie.max_age) |ma| {
        try buf.appendSlice(arena, "; Max-Age=");
        try std.fmt.format(buf.writer(arena), "{d}", .{ma});
    }

    if (cookie.http_only) {
        try buf.appendSlice(arena, "; HttpOnly");
    }
    if (cookie.secure) {
        try buf.appendSlice(arena, "; Secure");
    }
    if (cookie.partitioned) {
        try buf.appendSlice(arena, "; Partitioned");
    }

    if (cookie.same_site) |ss| switch (ss) {
        .lax => try buf.appendSlice(arena, "; SameSite=Lax"),
        .strict => try buf.appendSlice(arena, "; SameSite=Strict"),
        .none => try buf.appendSlice(arena, "; SameSite=None"),
    };

    return buf.items;
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
        var writer: std.io.Writer = .fixed(&tst);
        try writer.printInt(i, 10, .lower, .{});
        const l = writeInt(&buf, @intCast(i));
        try t.expectString(tst[0..writer.end], buf[0..l]);
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

test "response: explit content length" {
    var ctx = t.Context.init(.{});
    defer ctx.deinit();

    var res = ctx.response();
    res.header("Key1", "Value1");
    res.header("Content-Length", "30");
    try res.write();
    try ctx.expect("HTTP/1.1 200 \r\nKey1: Value1\r\nContent-Length: 30\r\n\r\n");
}

test "response: setCookie" {
    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        try res.setCookie("c-n", "c-v", .{});
        try t.expectString("c-n=c-v", res.headers.get("Set-Cookie").?);
    }

    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        try res.setCookie("c-n2", "c,v", .{});
        try t.expectString("c-n2=\"c,v\"", res.headers.get("Set-Cookie").?);
    }

    {
        var ctx = t.Context.init(.{});
        defer ctx.deinit();

        var res = ctx.response();
        try res.setCookie("cookie_name3", "cookie value 3", .{
            .path = "/auth/",
            .domain = "www.openmymind.net",
            .max_age = 9001,
            .secure = true,
            .http_only = true,
            .partitioned = true,
            .same_site = .lax,
        });
        try t.expectString("cookie_name3=\"cookie value 3\"; Path=/auth/; Domain=www.openmymind.net; Max-Age=9001; HttpOnly; Secure; Partitioned; SameSite=Lax", res.headers.get("Set-Cookie").?);
    }
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
