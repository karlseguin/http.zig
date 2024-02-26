const std = @import("std");
const m = @import("metrics");

pub const RegistryOpts = m.RegistryOpts;

// defaults to noop metrics, making this safe to use
// whether or not initializeMetrics is called
var metrics = m.initializeNoop(Metrics);

const Metrics = struct {
    // number of connections
    connections: m.Counter(usize),

    // number of requests (which can be more than # of connections thanks to
    // keepalive)
    requests: m.Counter(usize),

    // number of connections that were timed out while service a request
    timeout_active: m.Counter(usize),

    // number of connections that were timed out while in keepalive
    timeout_keepalive: m.Counter(usize),

    // size, in bytes, of dynamically allocated memory by our buffer pool,
    // caused by the large buffer pool being empty.
    alloc_buffer_empty: m.Counter(u64),

    // size, in bytes, of dynamically allocated memory by our buffer pool,
    // caused by the required memory being larger than the large buffer size
    alloc_buffer_large: m.Counter(u64),

    // size, in bytes, of dynamically allocated memory used for unescaping URL
    // or form parameters
    alloc_unescape: m.Counter(u64),

    // some internal processing error (should be 0!)
    internal_error: m.Counter(usize),

    // requests which could not be parsed
    invalid_request: m.Counter(usize),
};

pub fn initialize(allocator: std.mem.Allocator, comptime opts: m.RegistryOpts) !void {
    metrics = .{
        .connections = try m.Counter(usize).init(allocator, "httpz_connections", .{}, opts),
        .requests = try m.Counter(usize).init(allocator, "httpz_requests", .{}, opts),
        .timeout_active = try m.Counter(usize).init(allocator, "httpz_timeout_active", .{}, opts),
        .timeout_keepalive = try m.Counter(usize).init(allocator, "httpz_timeout_keepalive", .{}, opts),
        .alloc_buffer_empty = try m.Counter(u64).init(allocator, "httpz_alloc_buffer_empty", .{}, opts),
        .alloc_buffer_large = try m.Counter(u64).init(allocator, "httpz_alloc_buffer_large", .{}, opts),
        .alloc_unescape = try m.Counter(u64).init(allocator, "httpz_alloc_unescape", .{}, opts),
        .internal_error = try m.Counter(usize).init(allocator, "httpz_internal_error", .{}, opts),
        .invalid_request = try m.Counter(usize).init(allocator, "httpz_invalid_request", .{}, opts),
    };
}

pub fn write(writer: anytype) !void {
  return m.write(metrics, writer);
}

pub fn allocBufferEmpty(size: u64) void {
    metrics.alloc_buffer_empty.incrBy(size);
}

pub fn allocBufferLarge(size: u64) void {
    metrics.alloc_buffer_large.incrBy(size);
}

pub fn allocUnescape(size: u64) void {
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
