const m = @import("metrics");

// This is an advanced usage of metrics.zig, largely done because we aren't
// using any vectored metrics and thus can do everything at comptime.
var metrics = Metrics{
    .connections = m.Counter(usize).Impl.init("httpz_connections", .{}),
    .requests = m.Counter(usize).Impl.init("httpz_requests", .{}),
    .timeout_active = m.Counter(usize).Impl.init("httpz_timeout_active", .{}),
    .timeout_keepalive = m.Counter(usize).Impl.init("httpz_timeout_keepalive", .{}),
    .alloc_buffer_empty = m.Counter(usize).Impl.init("httpz_alloc_buffer_empty", .{}),
    .alloc_buffer_large = m.Counter(usize).Impl.init("httpz_alloc_buffer_large", .{}),
    .alloc_unescape = m.Counter(usize).Impl.init("httpz_alloc_unescape", .{}),
    .internal_error = m.Counter(usize).Impl.init("httpz_internal_error", .{}),
    .invalid_request = m.Counter(usize).Impl.init("httpz_invalid_request", .{}),
    .header_too_big = m.Counter(usize).Impl.init("httpz_header_too_big", .{}),
    .body_too_big = m.Counter(usize).Impl.init("httpz_body_too_big", .{}),
};

const Metrics = struct {
    // number of connections
    connections: m.Counter(usize).Impl,

    // number of requests (which can be more than # of connections thanks to
    // keepalive)
    requests: m.Counter(usize).Impl,

    // number of connections that were timed out while service a request
    timeout_active: m.Counter(usize).Impl,

    // number of connections that were timed out while in keepalive
    timeout_keepalive: m.Counter(usize).Impl,

    // size, in bytes, of dynamically allocated memory by our buffer pool,
    // caused by the large buffer pool being empty.
    alloc_buffer_empty: m.Counter(usize).Impl,

    // size, in bytes, of dynamically allocated memory by our buffer pool,
    // caused by the required memory being larger than the large buffer size
    alloc_buffer_large: m.Counter(usize).Impl,

    // size, in bytes, of dynamically allocated memory used for unescaping URL
    // or form parameters
    alloc_unescape: m.Counter(usize).Impl,

    // some internal processing error (should be 0!)
    internal_error: m.Counter(usize).Impl,

    // requests which could not be parsed
    invalid_request: m.Counter(usize).Impl,

    // requests which were rejected because the header was too big
    header_too_big: m.Counter(usize).Impl,

    // requests which were rejected because the body was too big
    body_too_big: m.Counter(usize).Impl,
};

pub fn write(writer: anytype) !void {
    try metrics.connections.write(writer);
    try metrics.requests.write(writer);
    try metrics.timeout_active.write(writer);
    try metrics.timeout_keepalive.write(writer);
    try metrics.alloc_buffer_empty.write(writer);
    try metrics.alloc_buffer_large.write(writer);
    try metrics.alloc_unescape.write(writer);
    try metrics.internal_error.write(writer);
    try metrics.invalid_request.write(writer);
    try metrics.header_too_big.write(writer);
    try metrics.body_too_big.write(writer);
}

pub fn allocBufferEmpty(size: usize) void {
    metrics.alloc_buffer_empty.incrBy(size);
}

pub fn allocBufferLarge(size: usize) void {
    metrics.alloc_buffer_large.incrBy(size);
}

pub fn allocUnescape(size: usize) void {
    metrics.alloc_unescape.incrBy(size);
}

pub fn connection() void {
    metrics.connections.incr();
}

pub fn request() void {
    metrics.requests.incr();
}

pub fn timeoutActive(count: usize) void {
    metrics.timeout_active.incrBy(count);
}

pub fn timeoutKeepalive(count: usize) void {
    metrics.timeout_keepalive.incrBy(count);
}

pub fn internalError() void {
    metrics.internal_error.incr();
}

pub fn invalidRequest() void {
    metrics.invalid_request.incr();
}

pub fn headerTooBig() void {
    metrics.header_too_big.incr();
}

pub fn bodyTooBig() void {
    metrics.body_too_big.incr();
}
