const std = @import("std");

const os = std.os;
const http = @import("httpz.zig");
const buffer = @import("buffer.zig");
const metrics = @import("metrics.zig");

const Self = @This();

const Url = @import("url.zig").Url;
const Conn = @import("worker.zig").Conn;
const Params = @import("params.zig").Params;
const KeyValue = @import("key_value.zig").KeyValue;
const MultiFormKeyValue = @import("key_value.zig").MultiFormKeyValue;
const Config = @import("config.zig").Config.Request;

const Stream = std.net.Stream;
const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// this approach to matching method name comes from zhp
const GET_ = @as(u32, @bitCast([4]u8{ 'G', 'E', 'T', ' ' }));
const PUT_ = @as(u32, @bitCast([4]u8{ 'P', 'U', 'T', ' ' }));
const POST = @as(u32, @bitCast([4]u8{ 'P', 'O', 'S', 'T' }));
const HEAD = @as(u32, @bitCast([4]u8{ 'H', 'E', 'A', 'D' }));
const PATC = @as(u32, @bitCast([4]u8{ 'P', 'A', 'T', 'C' }));
const DELE = @as(u32, @bitCast([4]u8{ 'D', 'E', 'L', 'E' }));
const OPTI = @as(u32, @bitCast([4]u8{ 'O', 'P', 'T', 'I' }));
const HTTP = @as(u32, @bitCast([4]u8{ 'H', 'T', 'T', 'P' }));
const V1P0 = @as(u32, @bitCast([4]u8{ '/', '1', '.', '0' }));
const V1P1 = @as(u32, @bitCast([4]u8{ '/', '1', '.', '1' }));

pub const Request = struct {
    // The URL of the request
    url: Url,

    // the address of the client
    address: Address,

    // Path params (extracted from the URL based on the route).
    // Using req.param(NAME) is preferred.
    params: Params,

    // The headers of the request. Using req.header(NAME) is preferred.
    headers: KeyValue,

    // The request method.
    method: http.Method,

    // The request protocol.
    protocol: http.Protocol,

    // The body of the request, if any.
    body_buffer: ?buffer.Buffer = null,
    body_len: usize = 0,

    // cannot use an optional on qs, because it's pre-allocated so always exists
    qs_read: bool = false,

    // The query string lookup.
    qs: KeyValue,

    // cannot use an optional on fd, because it's pre-allocated so always exists
    fd_read: bool = false,

    // The formData lookup.
    fd: KeyValue,

    // The multiFormData lookup.
    mfd: MultiFormKeyValue,

    // Spare space we still have in our static buffer after parsing the request
    // We can use this, if needed, for example to unescape querystring parameters
    spare: []u8,

    // An arena that will be reset at the end of each request. Can be used
    // internally by this framework. The application is also free to make use of
    // this arena. This is the same arena as response.arena.
    arena: Allocator,

    pub const State = Self.State;
    pub const Config = Self.Config;
    pub const Reader = Self.Reader;

    pub fn init(arena: Allocator, conn: *Conn) Request {
        const state = &conn.req_state;
        return .{
            .arena = arena,
            .qs = state.qs,
            .fd = state.fd,
            .mfd = state.mfd,
            .method = state.method.?,
            .protocol = state.protocol.?,
            .url = Url.parse(state.url.?),
            .address = conn.address,
            .params = state.params,
            .headers = state.headers,
            .body_buffer = state.body,
            .body_len = state.body_len,
            .spare = state.buf[state.pos..],
        };
    }

    pub fn canKeepAlive(self: *const Request) bool {
        return switch (self.protocol) {
            http.Protocol.HTTP11 => {
                if (self.headers.get("connection")) |conn| {
                    return !std.mem.eql(u8, conn, "close");
                }
                return true;
            },
            http.Protocol.HTTP10 => return false, // TODO: support this in the cases where it can be
        };
    }

    pub fn body(self: *const Request) ?[]const u8 {
        const buf = self.body_buffer orelse return null;
        return buf.data[0..self.body_len];
    }

    /// `name` should be full lowercase
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn query(self: *Request) !KeyValue {
        if (self.qs_read) {
            return self.qs;
        }
        return self.parseQuery();
    }

    pub fn json(self: *Request, comptime T: type) !?T {
        const b = self.body() orelse return null;
        return try std.json.parseFromSliceLeaky(T, self.arena, b, .{});
    }

    pub fn jsonValue(self: *Request) !?std.json.Value {
        const b = self.body() orelse return null;
        return try std.json.parseFromSliceLeaky(std.json.Value, self.arena, b, .{});
    }

    pub fn jsonObject(self: *Request) !?std.json.ObjectMap {
        const value = try self.jsonValue() orelse return null;
        switch (value) {
            .object => |o| return o,
            else => return null,
        }
    }

    pub fn formData(self: *Request) !KeyValue {
        if (self.fd_read) {
            return self.fd;
        }
        return self.parseFormData();
    }

    pub fn multiFormData(self: *Request) !MultiFormKeyValue {
        if (self.fd_read) {
            return self.mfd;
        }
        return self.parseMultiFormData();
    }

    // OK, this is a bit complicated.
    // We might need to allocate memory to parse the querystring. Specifically, if
    // there's a url-escaped component (a key or value), we need memory to store
    // the un-escaped version. Ideally, we'd like to use our static buffer for this
    // but, we might not have enough space.
    fn parseQuery(self: *Request) !KeyValue {
        const raw = self.url.query;
        if (raw.len == 0) {
            self.qs_read = true;
            return self.qs;
        }

        var qs = &self.qs;
        var buf = self.spare;
        const allocator = self.arena;

        var it = std.mem.splitScalar(u8, raw, '&');
        while (it.next()) |pair| {
            if (std.mem.indexOfScalarPos(u8, pair, 0, '=')) |sep| {
                const key_res = try Url.unescape(allocator, buf, pair[0..sep]);
                if (key_res.buffered) {
                    buf = buf[key_res.value.len..];
                }

                const value_res = try Url.unescape(allocator, buf, pair[sep + 1 ..]);
                if (value_res.buffered) {
                    buf = buf[value_res.value.len..];
                }

                qs.add(key_res.value, value_res.value);
            } else {
                const key_res = try Url.unescape(allocator, buf, pair);
                if (key_res.buffered) {
                    buf = buf[key_res.value.len..];
                }
                qs.add(key_res.value, "");
            }
        }

        self.spare = buf;
        self.qs_read = true;
        return self.qs;
    }

    fn parseFormData(self: *Request) !KeyValue {
        const b = self.body() orelse "";
        if (b.len == 0) {
            self.fd_read = true;
            return self.fd;
        }

        var fd = &self.fd;
        var buf = self.spare;
        const allocator = self.arena;

        var it = std.mem.splitScalar(u8, b, '&');
        while (it.next()) |pair| {
            if (std.mem.indexOfScalarPos(u8, pair, 0, '=')) |sep| {
                const key_res = try Url.unescape(allocator, buf, pair[0..sep]);
                if (key_res.buffered) {
                    buf = buf[key_res.value.len..];
                }

                const value_res = try Url.unescape(allocator, buf, pair[sep + 1 ..]);
                if (value_res.buffered) {
                    buf = buf[value_res.value.len..];
                }

                fd.add(key_res.value, value_res.value);
            } else {
                const key_res = try Url.unescape(allocator, buf, pair);
                if (key_res.buffered) {
                    buf = buf[key_res.value.len..];
                }
                fd.add(key_res.value, "");
            }
        }

        self.spare = buf;
        self.fd_read = true;
        return self.fd;
    }

    fn parseMultiFormData(self: *Request,) !MultiFormKeyValue {
        const body_ = self.body() orelse "";
        if (body_.len == 0) {
            self.fd_read = true;
            return self.mfd;
        }

        const content_type = blk: {
            if (self.header("content-type")) |content_type| {
                if (std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) {
                    break :blk content_type;
                }
            }
            return error.NotMultipartForm;
        };

        // Max boundary length is 70. Plus the two leading dashes (--)
        var boundary_buf: [72]u8 = undefined;
        const boundary = blk: {
            const directive = content_type["multipart/form-data".len..];
            for (directive, 0..) |b, i| loop: {
                if (b != ' ' and b != ';') {
                   if (std.ascii.startsWithIgnoreCase(directive[i..], "boundary=")) {
                        const raw_boundary = directive["boundary=".len + i..];
                        if (raw_boundary.len > 0 and raw_boundary.len <= 70) {
                            boundary_buf[0] = '-';
                            boundary_buf[1] = '-';
                            if (raw_boundary[0] == '"') {
                                if (raw_boundary.len > 2 and raw_boundary[raw_boundary.len - 1] == '"') {
                                    // it's really -2, since we need to strip out the two quotes
                                    // but buf is already at + 2, so they cancel out.
                                    const end = raw_boundary.len;
                                    @memcpy(boundary_buf[2..end], raw_boundary[1..raw_boundary.len - 1]);
                                    break :blk boundary_buf[0..end];
                                }
                            } else {
                                const end = 2 + raw_boundary.len;
                                @memcpy(boundary_buf[2..end], raw_boundary);
                                break :blk boundary_buf[0..end];
                            }
                        }
                   }
                   // not valid, break out of the loop so we can return
                   // an error.InvalidMultiPartFormDataHeader
                   break :loop;
                }
            }
            return error.InvalidMultiPartFormDataHeader;
        };

        var mfd = &self.mfd;
        var entry_it = std.mem.splitSequence(u8, body_, boundary);

        {
            // We expect the body to begin with a boundary
            const first = entry_it.next() orelse {
                self.fd_read = true;
                return self.mfd;
            };
            if (first.len != 0) {
                return error.InvalidMultiPartEncoding;
            }
        }

        while (entry_it.next()) |entry| {
            // body ends with -- after a final boundary
            if (entry.len == 4 and entry[0] == '-' and entry[1] == '-' and entry[2] == '\r' and entry[3] == '\n') {
                break;
            }

            if (entry.len < 2 or entry[0] != '\r' or entry[1] != '\n') return error.InvalidMultiPartEncoding;

            // [2..] to skip our boundary's trailing line terminator
            const field = try parseMultiPartEntry(entry[2..]);
            mfd.add(field.name, field.value);
        }

        self.fd_read = true;
        return self.mfd;
    }

    const MultiPartField = struct {
        name: []const u8,
        value: MultiFormKeyValue.Value,
    };

    // I'm sorry
    fn parseMultiPartEntry(entry: []const u8) !MultiPartField {
        var pos: usize = 0;
        var attributes: ?ContentDispostionAttributes = null;

        while (true) {
            const end_line_pos = std.mem.indexOfScalarPos(u8, entry, pos, '\n') orelse return error.InvalidMultiPartEncoding;
            const line = entry[pos..end_line_pos];

            pos = end_line_pos + 1;
            if (line.len == 0 or line[line.len - 1] != '\r') return error.InvalidMultiPartEncoding;

            if (line.len == 1) {
                break;
            }

            // we need to look for the name
            if (std.ascii.startsWithIgnoreCase(line, "content-disposition:") == false) {
                continue;
            }

            const value =  trimLeadingSpace(line["content-disposition:".len ..]);
            if (std.ascii.startsWithIgnoreCase(value, "form-data;") == false) {
                return error.InvalidMultiPartEncoding;
            }

            // constCast is safe here because we know this ultilately comes from one of our buffers
            const value_start = "form-data;".len;
            const value_end = value.len - 1; // remove the trailing \r
            attributes = try getContentDispotionAttributes(@constCast(trimLeadingSpace(value[value_start..value_end])));
        }

        const value = entry[pos..];
        if (value.len < 2 or value[value.len - 2] != '\r' or value[value.len - 1] != '\n') {
            return error.InvalidMultiPartEncoding;
        }

        const attr = attributes orelse return error.InvalidMultiPartEncoding;

        return .{
            .name = attr.name,
            .value = .{
                .value = value[0..value.len - 2],
                .filename = attr.filename,
            },
        };
    }

    const ContentDispostionAttributes = struct {
        name: []const u8,
        filename: ?[]const u8 = null,
    };

    // I'm sorry
    fn getContentDispotionAttributes(fields: []u8) !ContentDispostionAttributes{
        var pos: usize = 0;

        var name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;

        while (pos < fields.len) {
            {
                const b = fields[pos];
                if (b == ';' or b == ' ' or b == '\t') {
                    pos += 1;
                    continue;
                }
            }

            const sep = std.mem.indexOfScalarPos(u8, fields, pos, '=') orelse return error.InvalidMultiPartEncoding;
            const field_name = fields[pos..sep];

            // skip the equal
            const value_start = sep + 1;
            if (value_start == fields.len) {
                return error.InvalidMultiPartEncoding;
            }

            var value: []const u8 = undefined;
            if (fields[value_start] != '"') {
                const value_end = std.mem.indexOfScalarPos(u8, fields, pos, ';') orelse fields.len;
                pos = value_end;
                value = fields[value_start..value_end];
            } else blk: {
                // skip the double quote
                pos = value_start + 1;
                var write_pos = pos;
                while (pos < fields.len) {
                    switch (fields[pos]) {
                        '\\' => {
                            if (pos == fields.len) {
                                return error.InvalidMultiPartEncoding;
                            }
                            // supposedly MSIE doesn't always escape \, so if the \ isn't escape
                            // one of the special characters, it must be a single \. This is what Go does.
                            switch (fields[pos + 1]) {
                                // from Go's mime parser func isTSpecial(r rune) bool
                                '(', ')', '<', '>', '@', ',', ';', ':', '"', '/', '[', ']', '?', '=' => |n| {
                                    fields[write_pos] = n;
                                    pos += 1;
                                },
                                else => fields[write_pos] = '\\',
                            }

                        },
                        '"' => {
                            pos += 1;
                            value = fields[value_start + 1..write_pos];
                            break :blk;
                        },
                        else => |b| fields[write_pos] = b,
                    }
                    pos += 1;
                    write_pos += 1;
                }
                return error.InvalidMultiPartEncoding;
            }

            if (std.mem.eql(u8, field_name, "name")) {
                name = value;
            } else if (std.mem.eql(u8, field_name, "filename")) {
                filename = value;
            }
        }

        return .{
            .name = name orelse return error.InvalidMultiPartEncoding,
            .filename = filename,
        };
    }

};

// All the upfront memory allocation that we can do. Each worker keeps a pool
// of these to re-use.
pub const State = struct {
    // Header must fit in here. Extra space can be used to fit the body or decode
    // URL parameters.
    buf: []u8,

    // position in buf that we've parsed up to
    pos: usize,

    // length of buffer for which we have valid data
    len: usize,

    // Lazy-loaded in request.query();
    qs: KeyValue,

    // Lazy-loaded in request.formData();
    fd: KeyValue,

    // Lazy-loaded in request.multiFormData();
    mfd: MultiFormKeyValue,

    // Populated after we've parsed the request, once we're matching the request
    // to a route.
    params: Params,

    // constant config, but it's the only field we need,
    max_body_size: usize,

    // For reading the body, we might need more than `buf`.
    buffer_pool: *buffer.Pool,

    // URL, if we've parsed it
    url: ?[]u8,

    // Method, if we've parsed it
    method: ?http.Method,

    // Protocol, if we've parsed it
    protocol: ?http.Protocol,

    // The headers, might be partially parsed. From the outside, there's no way
    // to know if this is fully parsed or not. There doesn't have to be. This
    // is because once we finish parsing the headers, if there's no body, we'll
    // signal the worker that we have a complete request and it can proceed to
    // handle it. Thus, body == null or body_len == 0 doesn't mean anything.
    headers: KeyValue,

    // Our body. This be a slice pointing to` buf`, or be from the buffer_pool or
    // be dynamically allocated.
    body: ?buffer.Buffer,

    // position in body.data that we have valid data for
    body_pos: usize,

    // the full length of the body, we might not have that much data yet, but we
    // know what it is from the content-length header
    body_len: usize,

    arena: *ArenaAllocator,

    pub fn init(allocator: Allocator, arena: *ArenaAllocator, buffer_pool: *buffer.Pool, config: *const Config) !Request.State {
        return .{
            .pos = 0,
            .len = 0,
            .url = null,
            .method = null,
            .protocol = null,
            .body = null,
            .body_pos = 0,
            .body_len = 0,
            .arena = arena,
            .buffer_pool = buffer_pool,
            .max_body_size = config.max_body_size orelse 1_048_576,
            .qs = try KeyValue.init(allocator, config.max_query_count orelse 32),
            .fd = try KeyValue.init(allocator, config.max_form_count orelse 0),
            .mfd = try MultiFormKeyValue.init(allocator, config.max_multiform_count orelse 0),
            .buf = try allocator.alloc(u8, config.buffer_size orelse 32_768),
            .headers = try KeyValue.init(allocator, config.max_header_count orelse 32),
            .params = try Params.init(allocator, config.max_param_count orelse 10),
        };
    }

    pub fn deinit(self: *State, allocator: Allocator) void {
        // not our job to clear the arena!
        if (self.body) |buf| {
            self.buffer_pool.release(buf);
            self.body = null;
        }
        allocator.free(self.buf);
        self.qs.deinit(allocator);
        self.fd.deinit(allocator);
        self.mfd.deinit(allocator);
        self.params.deinit(allocator);
        self.headers.deinit(allocator);
    }

    pub fn reset(self: *State) void {
        // not our job to clear the arena!
        self.pos = 0;
        self.len = 0;
        self.url = null;
        self.method = null;
        self.protocol = null;

        self.body_pos = 0;
        self.body_len = 0;
        if (self.body) |buf| {
            self.buffer_pool.release(buf);
            self.body = null;
        }

        self.qs.reset();
        self.fd.reset();
        self.mfd.reset();
        self.params.reset();
        self.headers.reset();
    }

    // returns true if the header has been fully parsed
    pub fn parse(self: *State, stream: anytype) !bool {
        if (self.body != null) {
            // if we have a body, then we've read the header. We want to read into
            // self.body, not self.buf.
            return self.readBody(stream);
        }

        var len = self.len;
        const buf = self.buf;
        const n = try stream.read(buf[len..]);
        if (n == 0) {
            return error.ConnectionClosed;
        }
        len = len + n;
        self.len = len;

        if (self.method == null) {
            if (try self.parseMethod(buf[0..len])) return true;
        } else if (self.url == null) {
            if (try self.parseUrl(buf[self.pos..len])) return true;
        } else if (self.protocol == null) {
            if (try self.parseProtocol(buf[self.pos..len])) return true;
        } else {
            if (try self.parseHeaders(buf[self.pos..len])) return true;
        }

        if (self.body == null and len == buf.len) {
            metrics.headerTooBig();
            return error.HeaderTooBig;
        }
        return false;
    }

    fn parseMethod(self: *State, buf: []u8) !bool {
        const buf_len = buf.len;
        if (buf_len < 4) return false;

        switch (@as(u32, @bitCast(buf[0..4].*))) {
            GET_ => {
                self.pos = 4;
                self.method = .GET;
            },
            PUT_ => {
                self.pos = 4;
                self.method = .PUT;
            },
            POST => {
                if (buf_len < 5) return false;
                if (buf[4] != ' ') return error.UnknownMethod;
                self.pos = 5;
                self.method = .POST;
            },
            HEAD => {
                if (buf_len < 5) return false;
                if (buf[4] != ' ') return error.UnknownMethod;
                self.pos = 5;
                self.method = .HEAD;
            },
            PATC => {
                if (buf_len < 6) return false;
                if (buf[4] != 'H' or buf[5] != ' ') return error.UnknownMethod;
                self.pos = 6;
                self.method = .PATCH;
            },
            DELE => {
                if (buf_len < 7) return false;
                if (buf[4] != 'T' or buf[5] != 'E' or buf[6] != ' ') return error.UnknownMethod;
                self.pos = 7;
                self.method = .DELETE;
            },
            OPTI => {
                if (buf_len < 8) return false;
                if (buf[4] != 'O' or buf[5] != 'N' or buf[6] != 'S' or buf[7] != ' ') return error.UnknownMethod;
                self.pos = 8;
                self.method = .OPTIONS;
            },
            else => return error.UnknownMethod,
        }

        return try self.parseUrl(buf[self.pos..]);
    }

    fn parseUrl(self: *State, buf: []u8) !bool {
        const buf_len = buf.len;
        if (buf_len == 0) return false;

        var len: usize = 0;
        switch (buf[0]) {
            '/' => {
                const end_index = std.mem.indexOfScalarPos(u8, buf[1..buf_len], 0, ' ') orelse return false;
                // +1 since we skipped the leading / in our indexOfScalar and +1 to consume the space
                len = end_index + 2;
                const url = buf[0 .. end_index + 1];
                if (!Url.isValid(url)) return error.InvalidRequestTarget;
                self.url = url;
            },
            '*' => {
                if (buf_len == 1) return false;
                // Read never returns 0, so if we're here, buf.len >= 1
                if (buf[1] != ' ') return error.InvalidRequestTarget;
                len = 2;
                self.url = buf[0..1];
            },
            // TODO: Support absolute-form target (e.g. http://....)
            else => return error.InvalidRequestTarget,
        }

        self.pos += len;
        return self.parseProtocol(buf[len..]);
    }

    fn parseProtocol(self: *State, buf: []u8) !bool {
        const buf_len = buf.len;
        if (buf_len < 10) return false;

        if (@as(u32, @bitCast(buf[0..4].*)) != HTTP) {
            return error.UnknownProtocol;
        }

        self.protocol = switch (@as(u32, @bitCast(buf[4..8].*))) {
            V1P1 => http.Protocol.HTTP11,
            V1P0 => http.Protocol.HTTP10,
            else => return error.UnsupportedProtocol,
        };

        if (buf[8] != '\r' or buf[9] != '\n') {
            return error.UnknownProtocol;
        }

        self.pos += 10;
        return try self.parseHeaders(buf[10..]);
    }

    fn parseHeaders(self: *State, full: []u8) !bool {
        var pos = self.pos;
        var headers = &self.headers;

        var buf = full;
        while (true) {
            const trailer_end = std.mem.indexOfScalar(u8, buf, '\n') orelse return false;
            if (trailer_end == 0 or buf[trailer_end - 1] != '\r') return error.InvalidHeaderLine;

            // means this follows the last \r\n, which means it's the end of our headers
            if (trailer_end == 1) {
                self.pos += 2;
                return try self.prepareForBody();
            }

            var valid = false;
            const header_end = trailer_end - 1;
            for (buf[0..header_end], 0..) |b, i| {
                // find the colon and lowercase the header while we're iterating
                if ('A' <= b and b <= 'Z') {
                    buf[i] = b + 32;
                    continue;
                }
                if (b != ':') {
                    if (ALLOWED_HEADER_NAME_BYTES[b] == false) {
                        break;
                    }
                    continue;
                }

                const name = buf[0..i];
                const value = trimLeadingSpace(buf[i + 1 .. header_end]);
                for (value) |vb| {
                    if (ALLOWED_HEADER_VALUE_BYTES[vb] == false) {
                        break;
                    }
                }
                headers.add(name, value);
                valid = true;
                break;
            }
            if (!valid) {
                return error.InvalidHeaderLine;
            }

            pos = trailer_end + 1;
            self.pos += pos;
            buf = buf[pos..];
        }
    }

    // we've finished reading the header
    fn prepareForBody(self: *State) !bool {
        const str = self.headers.get("content-length") orelse return true;
        const cl = atoi(str) orelse return error.InvalidContentLength;

        self.body_len = cl;
        if (cl == 0) return true;

        if (cl > self.max_body_size) {
            metrics.bodyTooBig();
            return error.BodyTooBig;
        }

        const pos = self.pos;
        const len = self.len;
        const buf = self.buf;

        // how much (if any) of the body we've already read
        const read = len - pos;

        if (read == cl) {
            // we've read the entire body into buf, point to that.
            self.body = .{ .type = .static, .data = buf[pos..len] };
            self.pos = len;
            return true;
        }

        // how much fo the body are we missing
        const missing = cl - read;

        // how much spare space we have in our static buffer
        const spare = buf.len - len;
        if (missing < spare) {
            // we don't have the [full] body, but we have enough space in our static
            // buffer for it
            self.body = .{ .type = .static, .data = buf[pos .. pos + cl] };

            // While we don't have this yet, we know that this will be the final
            // position of valid data within self.buf. We need this so that
            // we create create our `spare` slice, we can slice starting from
            // self.pos (everything before that is the full raw request)
            self.pos = len + missing;
        } else {
            // We don't have the [full] body, and our static buffer is too small
            const body_buf = try self.buffer_pool.arenaAlloc(self.arena.allocator(), cl);
            @memcpy(body_buf.data[0..read], buf[pos .. pos + read]);
            self.body = body_buf;
        }
        self.body_pos = read;
        return false;
    }

    fn readBody(self: *State, stream: anytype) !bool {
        var pos = self.body_pos;
        const buf = self.body.?.data;

        const n = try stream.read(buf[pos..]);
        if (n == 0) {
            return error.ConnectionClosed;
        }
        pos += n;
        if (pos == self.body_len) {
            return true;
        }
        self.body_pos = pos;
        return false;
    }
};

const ALLOWED_HEADER_NAME_BYTES: [255]bool = blk: {
    var all = std.mem.zeroes([255]bool);
    for ('a'..('z' + 1)) |b| all[b] = true;
    for ('A'..('Z' + 1)) |b| all[b] = true;
    for ('0'..('9' + 1)) |b| all[b] = true;
    all['-'] = true;
    all['_'] = true;
    break :blk all;
};

const ALLOWED_HEADER_VALUE_BYTES: [255]bool = blk: {
    var all = std.mem.zeroes([255]bool);
    for ('a'..('z' + 1)) |b| all[b] = true;
    for ('A'..('Z' + 1)) |b| all[b] = true;
    for ('0'..('9' + 1)) |b| all[b] = true;
    for ([_]u8{ ':', ';', '.', ',', '\\', '/', '"', '\'', '?', '!', '(', ')', '{', '}', '[', ']', '@', '<', '>', '=', '-', '+', '*', '#', '$', '&', '`', '|', '~', '^', '%' }) |b| {
        all[b] = true;
    }
    break :blk all;
};

inline fn trimLeadingSpace(in: []const u8) []const u8 {
    // very common case where we have a single space after our colon
    if (in.len >= 2 and in[0] == ' ' and in[1] != ' ') return in[1..];

    for (in, 0..) |b, i| {
        if (b != ' ' and b != '\t') return in[i..];
    }
    return "";
}

fn atoi(str: []const u8) ?usize {
    if (str.len == 0) {
        return null;
    }

    var n: usize = 0;
    for (str) |b| {
        const d = b - '0';
        if (d > 9) {
            return null;
        }
        n = n * 10 + @as(usize, @intCast(d));
    }
    return n;
}

const t = @import("t.zig");
test "atoi" {
    var buf: [5]u8 = undefined;
    for (0..99999) |i| {
        const n = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
        try t.expectEqual(i, atoi(buf[0..n]).?);
    }

    try t.expectEqual(null, atoi(""));
    try t.expectEqual(null, atoi("392a"));
    try t.expectEqual(null, atoi("b392"));
    try t.expectEqual(null, atoi("3c92"));
}

test "request: header too big" {
    try expectParseError(error.HeaderTooBig, "GET / HTTP/1.1\r\n\r\n", .{ .buffer_size = 17 });
    try expectParseError(error.HeaderTooBig, "GET / HTTP/1.1\r\nH: v\r\n\r\n", .{ .buffer_size = 23 });
}

test "request: parse method" {
    defer t.reset();
    {
        try expectParseError(error.UnknownMethod, "GETT ", .{});
        try expectParseError(error.UnknownMethod, " PUT ", .{});
    }

    {
        const r = try testParse("GET / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(http.Method.GET, r.method);
    }

    {
        const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(http.Method.PUT, r.method);
    }

    {
        const r = try testParse("POST / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(http.Method.POST, r.method);
    }

    {
        const r = try testParse("HEAD / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(http.Method.HEAD, r.method);
    }

    {
        const r = try testParse("PATCH / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(http.Method.PATCH, r.method);
    }

    {
        const r = try testParse("DELETE / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(http.Method.DELETE, r.method);
    }

    {
        const r = try testParse("OPTIONS / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(http.Method.OPTIONS, r.method);
    }
}

test "request: parse request target" {
    defer t.reset();
    {
        try expectParseError(error.InvalidRequestTarget, "GET NOPE", .{});
        try expectParseError(error.InvalidRequestTarget, "GET nope ", .{});
        try expectParseError(error.InvalidRequestTarget, "GET http://www.pondzpondz.com/test ", .{}); // this should be valid
        try expectParseError(error.InvalidRequestTarget, "PUT hello ", .{});
        try expectParseError(error.InvalidRequestTarget, "POST  /hello ", .{});
        try expectParseError(error.InvalidRequestTarget, "POST *hello ", .{});
    }

    {
        const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
        try t.expectString("/", r.url.raw);
    }

    {
        const r = try testParse("PUT /api/v2 HTTP/1.1\r\n\r\n", .{});
        try t.expectString("/api/v2", r.url.raw);
    }

    {
        const r = try testParse("DELETE /API/v2?hack=true&over=9000%20!! HTTP/1.1\r\n\r\n", .{});
        try t.expectString("/API/v2?hack=true&over=9000%20!!", r.url.raw);
    }

    {
        const r = try testParse("PUT * HTTP/1.1\r\n\r\n", .{});
        try t.expectString("*", r.url.raw);
    }
}

test "request: parse protocol" {
    defer t.reset();
    {
        try expectParseError(error.UnknownProtocol, "GET / http/1.1\r\n", .{});
        try expectParseError(error.UnsupportedProtocol, "GET / HTTP/2.0\r\n", .{});
    }

    {
        const r = try testParse("PUT / HTTP/1.0\r\n\r\n", .{});
        try t.expectEqual(http.Protocol.HTTP10, r.protocol);
    }

    {
        const r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(http.Protocol.HTTP11, r.protocol);
    }
}

test "request: parse headers" {
    defer t.reset();
    {
        try expectParseError(error.InvalidHeaderLine, "GET / HTTP/1.1\r\nHost\r\n", .{});
    }

    {
        const r = try testParse("PUT / HTTP/1.0\r\n\r\n", .{});
        try t.expectEqual(0, r.headers.len);
    }

    {
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\n\r\n", .{});

        try t.expectEqual(1, r.headers.len);
        try t.expectString("pondzpondz.com", r.headers.get("host").?);
    }

    {
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nMisc:  Some-Value\r\nAuthorization:none\r\n\r\n", .{});
        try t.expectEqual(3, r.headers.len);
        try t.expectString("pondzpondz.com", r.header("host").?);
        try t.expectString("Some-Value", r.header("misc").?);
        try t.expectString("none", r.header("authorization").?);
    }
}

test "request: canKeepAlive" {
    defer t.reset();
    {
        // implicitly keepalive for 1.1
        var r = try testParse("GET / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(true, r.canKeepAlive());
    }

    {
        // explicitly keepalive for 1.1
        var r = try testParse("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n", .{});
        try t.expectEqual(true, r.canKeepAlive());
    }

    {
        // explicitly not keepalive for 1.1
        var r = try testParse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", .{});
        try t.expectEqual(false, r.canKeepAlive());
    }
}

test "request: query" {
    defer t.reset();
    {
        // none
        var r = try testParse("PUT / HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(0, (try r.query()).len);
    }

    {
        // none with path
        var r = try testParse("PUT /why/would/this/matter HTTP/1.1\r\n\r\n", .{});
        try t.expectEqual(0, (try r.query()).len);
    }

    {
        // value-less
        var r = try testParse("PUT /?a HTTP/1.1\r\n\r\n", .{});
        const query = try r.query();
        try t.expectEqual(1, query.len);
        try t.expectString("", query.get("a").?);
        try t.expectEqual(null, query.get("b"));
    }

    {
        // single
        var r = try testParse("PUT /?a=1 HTTP/1.1\r\n\r\n", .{});
        const query = try r.query();
        try t.expectEqual(1, query.len);
        try t.expectString("1", query.get("a").?);
        try t.expectEqual(null, query.get("b"));
    }

    {
        // multiple
        var r = try testParse("PUT /path?Teg=Tea&it%20%20IS=over%209000%24&ha%09ck HTTP/1.1\r\n\r\n", .{});
        const query = try r.query();
        try t.expectEqual(3, query.len);
        try t.expectString("Tea", query.get("Teg").?);
        try t.expectString("over 9000$", query.get("it  IS").?);
        try t.expectString("", query.get("ha\tck").?);
    }
}

test "request: body content-length" {
    defer t.reset();
    {
        // too big
        try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{ .max_body_size = 9 });
    }

    {
        // no body
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
        try t.expectEqual(null, r.body());
        try t.expectEqual(null, r.body());
    }

    {
        // fits into static buffer
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
        try t.expectString("Over 9000!", r.body().?);
        try t.expectString("Over 9000!", r.body().?);
    }

    {
        // Requires dynamic buffer
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 11\r\n\r\nOver 9001!!", .{ .buffer_size = 40 });
        try t.expectString("Over 9001!!", r.body().?);
        try t.expectString("Over 9001!!", r.body().?);
    }
}

// the query and body both (can) occupy space in our static buffer
test "request: query & body" {
    defer t.reset();

    // query then body
    var r = try testParse("POST /?search=keemun%20tea HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
    try t.expectString("keemun tea", (try r.query()).get("search").?);
    try t.expectString("Over 9000!", r.body().?);

    // results should be cached internally, but let's double check
    try t.expectString("keemun tea", (try r.query()).get("search").?);
}

test "body: json" {
    defer t.reset();
    const Tea = struct {
        type: []const u8,
    };

    {
        // too big
        try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{ .max_body_size = 16 });
    }

    {
        // no body
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
        try t.expectEqual(null, try r.json(Tea));
        try t.expectEqual(null, try r.json(Tea));
    }

    {
        // parses json
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
        try t.expectString("keemun", (try r.json(Tea)).?.type);
        try t.expectString("keemun", (try r.json(Tea)).?.type);
    }
}

test "body: jsonValue" {
    defer t.reset();
    {
        // too big
        try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{ .max_body_size = 16 });
    }

    {
        // no body
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
        try t.expectEqual(null, try r.jsonValue());
        try t.expectEqual(null, try r.jsonValue());
    }

    {
        // parses json
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
        try t.expectString("keemun", (try r.jsonValue()).?.object.get("type").?.string);
        try t.expectString("keemun", (try r.jsonValue()).?.object.get("type").?.string);
    }
}

test "body: jsonObject" {
    defer t.reset();
    {
        // too big
        try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{ .max_body_size = 16 });
    }

    {
        // no body
        var r = try testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
        try t.expectEqual(null, try r.jsonObject());
        try t.expectEqual(null, try r.jsonObject());
    }

    {
        // not an object
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 7\r\n\r\n\"hello\"", .{});
        try t.expectEqual(null, try r.jsonObject());
        try t.expectEqual(null, try r.jsonObject());
    }

    {
        // parses json
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
        try t.expectString("keemun", (try r.jsonObject()).?.get("type").?.string);
        try t.expectString("keemun", (try r.jsonObject()).?.get("type").?.string);
    }
}

test "body: formData" {
    defer t.reset();
    {
        // too big
        try expectParseError(error.BodyTooBig, "POST / HTTP/1.0\r\nContent-Length: 22\r\n\r\nname=test", .{ .max_body_size = 21 });
    }

    {
        // no body
        var r = try testParse("POST / HTTP/1.0\r\n\r\nContent-Length: 0\r\n\r\n", .{ .max_body_size = 10 });
        const formData = try r.formData();
        try t.expectEqual(null, formData.get("name"));
        try t.expectEqual(null, formData.get("name"));
    }

    {
        // parses formData
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 9\r\n\r\nname=test", .{.max_form_count = 2});
        const formData = try r.formData();
        try t.expectString("test", formData.get("name").?);
        try t.expectString("test", formData.get("name").?);
    }

    {
        // multiple inputs
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 25\r\n\r\nname=test1&password=test2", .{.max_form_count = 2});

        const formData = try r.formData();
        try t.expectString("test1", formData.get("name").?);
        try t.expectString("test1", formData.get("name").?);

        try t.expectString("test2", formData.get("password").?);
        try t.expectString("test2", formData.get("password").?);
    }

    {
        // test decoding
        var r = try testParse("POST / HTTP/1.0\r\nContent-Length: 44\r\n\r\ntest=%21%40%23%24%25%5E%26*%29%28-%3D%2B%7C+", .{.max_form_count = 2});

        const formData = try r.formData();
        try t.expectString("!@#$%^&*)(-=+| ", formData.get("test").?);
        try t.expectString("!@#$%^&*)(-=+| ", formData.get("test").?);
    }
}

test "body: multiFormData valid" {
    defer t.reset();

    {
        // no body
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=BX1"
        }, &.{}), .{.max_multiform_count = 5});
        const formData = try r.multiFormData();
        try t.expectEqual(0, formData.len);
    }

    {
        // parses single field
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=-90x"
        }, &.{
            "---90x\r\n",
            "Content-Disposition: form-data; name=\"description\"\r\n\r\n",
            "the-desc\r\n",
            "---90x--\r\n"
        }), .{.max_multiform_count = 5});

        const formData = try r.multiFormData();
        try t.expectString("the-desc", formData.get("description").?.value);
        try t.expectString("the-desc", formData.get("description").?.value);
    }

    {
        // parses single field with filename
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=-90x"
        }, &.{
            "---90x\r\n",
            "Content-Disposition: form-data; filename=\"file1.zig\"; name=file\r\n\r\n",
            "some binary data\r\n",
            "---90x--\r\n"
        }), .{.max_multiform_count = 5});

        const formData = try r.multiFormData();
        const field = formData.get("file").?;
        try t.expectString("some binary data", field.value);
        try t.expectString("file1.zig", field.filename.?);
    }

    {
        // quoted boundary
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=\"-90x\""
        }, &.{
            "---90x\r\n",
            "Content-Disposition: form-data; name=\"description\"\r\n\r\n",
            "the-desc\r\n",
            "---90x--\r\n"
        }), .{.max_multiform_count = 5});


        const formData = try r.multiFormData();
        const field = formData.get("description").?;
        try t.expectEqual(null, field.filename);
        try t.expectString("the-desc", field.value);
    }

    {
        // multiple fields
        var r = try testParse(buildRequest(&.{
            "GET /something HTTP/1.1",
            "Content-Type: multipart/form-data; boundary=----99900AB"
        }, &.{
            "------99900AB\r\n",
            "content-type: text/plain; charset=utf-8\r\n",
            "content-disposition: form-data; name=\"fie\\\" \\?l\\d\"\r\n\r\n",
            "Value - 1\r\n",
            "------99900AB\r\n",
            "Content-Disposition: form-data; filename=another.zip; name=field2\r\n\r\n",
            "Value - 2\r\n",
            "------99900AB--\r\n"
        }), .{.max_multiform_count = 5});

        const formData = try r.multiFormData();
        try t.expectEqual(2, formData.len);

        const field1 = formData.get("fie\" ?l\\d").?;
        try t.expectEqual(null, field1.filename);
        try t.expectString("Value - 1", field1.value);

        const field2 = formData.get("field2").?;
        try t.expectString("Value - 2", field2.value);
        try t.expectString("another.zip", field2.filename.?);
    }

    {
        // enforce limit
        var r = try testParse(buildRequest(&.{
            "GET /something HTTP/1.1",
            "Content-Type: multipart/form-data; boundary=----99900AB"
        }, &.{
            "------99900AB\r\n",
            "Content-Type: text/plain; charset=utf-8\r\n",
            "Content-Disposition: form-data; name=\"fie\\\" \\?l\\d\"\r\n\r\n",
            "Value - 1\r\n",
            "------99900AB\r\n",
            "Content-Disposition: form-data; filename=another; name=field2\r\n\r\n",
            "Value - 2\r\n",
            "------99900AB--\r\n"
        }), .{.max_multiform_count = 1});

        defer t.reset();
        const formData = try r.multiFormData();
        try t.expectEqual(1, formData.len);
        try t.expectString("Value - 1", formData.get("fie\" ?l\\d").?.value);
    }
}

test "body: multiFormData invalid" {
    defer t.reset();
    {
        // large boudary
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=12345678901234567890123456789012345678901234567890123456789012345678901"
        }, &.{"garbage"}), .{});
        try t.expectError(error.InvalidMultiPartFormDataHeader, r.multiFormData());
    }

    {
        // no closing quote
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=\"123"
        }, &.{"garbage"}), .{});
        try t.expectError(error.InvalidMultiPartFormDataHeader, r.multiFormData());
    }

    {
        // no content-dispostion field header
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=-90x"
        }, &.{
            "---90x\r\n",
            "the-desc\r\n",
            "---90x--\r\n"
        }), .{.max_multiform_count = 5});
        try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
    }

    {
        // no content dispotion naem
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=-90x"
        }, &.{
            "---90x\r\n",
            "Content-Disposition: form-data; x=a",
            "the-desc\r\n",
            "---90x--\r\n"
        }), .{.max_multiform_count = 5});
        try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
    }

    {
        // missing name end quote
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=-90x"
        }, &.{
            "---90x\r\n",
            "Content-Disposition: form-data; name=\"hello\r\n\r\n",
            "the-desc\r\n",
            "---90x--\r\n"
        }), .{.max_multiform_count = 5});
        try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
    }

    {
        // missing missing newline
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=-90x"
        }, &.{
            "---90x\r\n",
            "Content-Disposition: form-data; name=hello\r\n",
            "the-desc\r\n",
            "---90x--\r\n"
        }), .{.max_multiform_count = 5});
        try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
    }

    {
        // missing missing newline x2
        var r = try testParse(buildRequest(&.{
            "POST / HTTP/1.0",
            "Content-Type: multipart/form-data; boundary=-90x"
        }, &.{
            "---90x\r\n",
            "Content-Disposition: form-data; name=hello",
            "the-desc\r\n",
            "---90x--\r\n"
        }), .{.max_multiform_count = 5});
        try t.expectError(error.InvalidMultiPartEncoding, r.multiFormData());
    }
}

// our t.Stream already simulates random TCP fragmentation.
test "request: fuzz" {
    // We have a bunch of data to allocate for testing, like header names and
    // values. Easier to use this arena and reset it after each test run.
    const aa = t.arena.allocator();
    defer t.reset();

    var r = t.getRandom();
    const random = r.random();
    for (0..100) |_| {
        // important to test with different buffer sizes, since there's a lot of
        // special handling for different cases (e.g the buffer is full and has
        // some of the body in it, so we need to copy that to a dynamically allocated
        // buffer)
        const buffer_size = random.uintAtMost(u16, 1024) + 1024;

        var ctx = t.Context.init(.{
            .request = .{ .buffer_size = buffer_size },
        });
        defer ctx.deinit();

        // how many requests should we make on this 1 individual socket (simulating
        // keepalive AND the request pool)
        const number_of_requests = random.uintAtMost(u8, 10) + 1;

        for (0..number_of_requests) |_| {
            defer if (@import("httpz.zig").blockingMode()) {
                ctx.conn.keepalive();
            } else {
                ctx.conn.keepaliveAndRestore() catch unreachable;
            };

            const method = randomMethod(random);
            const url = t.randomString(random, aa, 20);

            ctx.write(method);
            ctx.write(" /");
            ctx.write(url);

            const number_of_qs = random.uintAtMost(u8, 4);
            if (number_of_qs != 0) {
                ctx.write("?");
            }

            var query = std.StringHashMap([]const u8).init(aa);
            for (0..number_of_qs) |_| {
                const key = t.randomString(random, aa, 20);
                const value = t.randomString(random, aa, 20);
                if (!query.contains(key)) {
                    // TODO: figure out how we want to handle duplicate query values
                    // (the spec doesn't specifiy what to do)
                    query.put(key, value) catch unreachable;
                    ctx.write(key);
                    ctx.write("=");
                    ctx.write(value);
                    ctx.write("&");
                }
            }

            ctx.write(" HTTP/1.1\r\n");

            var headers = std.StringHashMap([]const u8).init(aa);
            for (0..random.uintAtMost(u8, 4)) |_| {
                const name = t.randomString(random, aa, 20);
                const value = t.randomString(random, aa, 20);
                if (!headers.contains(name)) {
                    // TODO: figure out how we want to handle duplicate query values
                    // Note, the spec says we should merge these!
                    headers.put(name, value) catch unreachable;
                    ctx.write(name);
                    ctx.write(": ");
                    ctx.write(value);
                    ctx.write("\r\n");
                }
            }

            var body: ?[]u8 = null;
            if (random.uintAtMost(u8, 4) == 0) {
                ctx.write("\r\n"); // no body
            } else {
                body = t.randomString(random, aa, 8000);
                const cl = std.fmt.allocPrint(aa, "{d}", .{body.?.len}) catch unreachable;
                headers.put("content-length", cl) catch unreachable;
                ctx.write("content-length: ");
                ctx.write(cl);
                ctx.write("\r\n\r\n");
                ctx.write(body.?);
            }

            var conn = ctx.conn;
            while (true) {
                const done = try conn.req_state.parse(ctx.stream);
                if (done) break;
            }

            var request = Request.init(conn.arena.allocator(), conn);

            // assert the headers
            var it = headers.iterator();
            while (it.next()) |entry| {
                try t.expectString(entry.value_ptr.*, request.header(entry.key_ptr.*).?);
            }

            // assert the querystring
            var actualQuery = request.query() catch unreachable;
            it = query.iterator();
            while (it.next()) |entry| {
                try t.expectString(entry.value_ptr.*, actualQuery.get(entry.key_ptr.*).?);
            }

            const actual_body = request.body();
            if (body) |b| {
                try t.expectString(b, actual_body.?);
            } else {
                try t.expectEqual(null, actual_body);
            }
        }
    }
}

fn testParse(input: []const u8, config: Config) !Request {
    var ctx = t.Context.allocInit(t.arena.allocator(), .{ .request = config });
    ctx.write(input);
    while (true) {
        const done = try ctx.conn.req_state.parse(ctx.stream);
        if (done) break;
    }
    return Request.init(ctx.conn.arena.allocator(), ctx.conn);
}

fn expectParseError(expected: anyerror, input: []const u8, config: Config) !void {
    var ctx = t.Context.init(.{ .request = config });
    defer ctx.deinit();

    ctx.write(input);
    try t.expectError(expected, ctx.conn.req_state.parse(ctx.stream));
}

fn randomMethod(random: std.rand.Random) []const u8 {
    return switch (random.uintAtMost(usize, 6)) {
        0 => "GET",
        1 => "PUT",
        2 => "POST",
        3 => "PATCH",
        4 => "DELETE",
        5 => "OPTIONS",
        6 => "HEAD",
        else => unreachable,
    };
}

fn buildRequest(header: []const []const u8, body: []const []const u8) []const u8 {
    var header_len: usize = 0;
    for (header) |h| {
        header_len += h.len;
    }

    var body_len: usize = 0;
    for (body) |b| {
        body_len += b.len;
    }

    var arr = std.ArrayList(u8).init(t.arena.allocator());
    // 100 for the Content-Length that we'll add and all the \r\n
    arr.ensureTotalCapacity(header_len + body_len + 100) catch unreachable;

    for (header) |h| {
        arr.appendSlice(h) catch unreachable;
        arr.appendSlice("\r\n") catch unreachable;
    }
    arr.appendSlice("Content-Length: ") catch unreachable;
    std.fmt.formatInt(body_len, 10, .lower, .{}, arr.writer()) catch unreachable;
    arr.appendSlice("\r\n\r\n") catch unreachable;

    for (body) |b| {
        arr.appendSlice(b) catch unreachable;
    }

    return arr.items;
}
