An HTTP/1.1 server for Zig.

# Installation
This library supports native Zig module (introduced in 0.11). Add a "httpz" dependency to your `build.zig.zon`.

# Usage

```zig
const httpz = @import("httpz");

fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var router = try httpz.router();

    // routes MUST be lowercase (params can use any casing).
    try router.get("/api/user/:id", getUser);

    // Overwrite the default notFound handler
    router.notFound(notFound)

    try httpz.listen(allocator, &router, .{
        .port = 5882,
        .errorHandler = errorHandler,
    });
}

fn getUser(req: *httpz.Request, res: *httpz.Response) !void {
    // the request comes with an arena allocator that you can use as needed
        const allocator = req.arena.allocator();
    var out = try std.fmt.allocPrint(allocator, "Hello {s}", req.param("id").?);
    res.setBody(out);
}

fn notFound(_: *httpz.Request, res: *httpz.Response) !void {
    res.status = 404;
    res.setBody("Not Found");
}

// note that the error handler return `void` and not `!void`
fn errorHandler(err: anyerror, _res: *httpz.Request, res: *httpz.Response) void {
    res.status = 500;
    res.setBody("Internal Server Error");
    std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{req.url.raw, err});
}
```

## httpz.Request
The main fields for this type are:

* `method` - an httpz.Method enum
* `arena` - an arena allocator that will be reset at the end of the request
* `url.path` - the path of the request 

To get a value from a URL parameter (as defined by the route using the `:NAME` syntax), use the `req.param(PARAM_NAME) ?[]const u8` method. Note that the parameter name matches the casing that you used when defining the route. The value will be lowercase (if the parameter exists).

To get a header vlaue, use `req.header(HEADER_NAME) ?[]const u8`. The `HEADER_NAME` must be lowercase. The value will be lowercase (if the header exists).

Getting a query string value is different than getting a header or parameter value. By default, httpz does not parse the querystring (because httpz itself doesn't need any information contained inside of it, unlike URL parameters and headers). To get a query value use:

```zig
const query = try req.query();
const value = query.get(KEY);
```

Note that `query()` can fail (parsing the querystring can require allocations if values are URL encoded). The `KEY` must be lowercase. The value will be lowercase (if the query value exists). The results of `req.query()` are internally cached, so calling it multiple times is ok.

## http.Response
You can set the status using the `status` field. By default, the status is set to 200.

You can set an arbitrary body using `setBody`. If you need dynamically allocated memory to create the body, consider using `req.arena`.

You can set a header using `res.header(NAME, VALUE)`. The `NAME` and `VALUE` are written in the response as-is (i.e. no changes are made to the casing or whitespacing).

## Router
You can use the `get`, `put`, `post`, `head`, `patch`, `delete` or `option` method of the router to define a router. You can also use the special `all` method to add a route for all methods.

### Casing
You **must** use a lowercase route. You can use any casing with parameter names, as long as you use that same casing when getting the parameter.

### Parameters
Routing supports parameters, via `:CAPTURE_NAME`. The captured values are available via `req.params.get(name: []const u8) ?[]const u8`.  

### Glob
You can glob an individual path segment, or the entire path suffix. For a suffix glob, it is important that no trailing slash is present.

```zig
// prefer using `try router.notFound(not_found)` than a global glob.
try router.all("/*", not_found);
try router.get("/api/*/debug")
```

When multiple globs are used, the most specific will be selected. E.g., give the following two routes:

```zig
try router.get("/*", not_found);
try router.get("/info/*", any_info)
```

A request for "/info/debug/all" will be routed to `any_info`, whereas a request for "/over/9000" will be routed to `not_found`.


### Limitations
The router has several limitations which might not get fixed. These specifically resolve around the interaction of globs, parameters and static path segments.

Given the following routes:

```zig
try router.get("/:any/users", route1);
try router.get("/hello/users/test", route2);
```

You would expect a request to "/hello/users" to be routed to `route1`. However, no route will be found. 

Globs interact similarly poorly with parameters and static path segments.

Resolving this issue requires keeping a stack (or visiting the routes recursively), in order to back-out of a dead-end and trying a different path.
This seems like an unnecessarily expensive thing to do, on each request, when, in my opinion, such route hierarchies are quite uncommon. 

## Configuration
The third option given to `listen` is an `httpz.Config` instance. Possible values, along with their default, are:

```zig
try httpz.listen(allocator, &router, .{
    // the port to listen on
    .port = 5882, 

    // the interface address to bind to
    .address = "127.0.0.1",

    .errorHandler = // defaults to a basic handler that will output 500 and log the error

    // various options for tweaking request processing
    .request = .{
        // Minimum number of request objects to keep pooled
        // This should be set to the same value as response.pool_size
        pool_size: usize = 100,

        // The maximum body size that we'll process. We'll can allocate up 
        // to this much memory per request for the body. Internally, we might
        // keep this memory around for a number of requests as an optimization.
        // So the maximum amount of memory that our request pool will use is in
        // the neighborhood of pool_size * max_body_size, but this value should be temporary
        // (there are more allocations, but this is the biggest chunk).
        max_body_size: usize = 1_048_576,

        // This memory is allocated upfront. The request header _must_ fit into
        // this space, else the request will be rejected. If possible, we'll 
        // try to load the body in here too. The minimum amount of memory that our request
        // pool will use is in the neighborhood of pool_size * buffer_size. It will never
        // be smaller than this (there are other static allocations, but this is the biggest chunk.)
        buffer_size: usize = 65_536,

        // The maximum number of headers to accept. 
        // Additional headers will be silently ignored.
        max_header_count: usize = 32,

        // the maximum number of URL parameters to accept.
        // Additional parameters will be silently ignored.
        max_param_count: usize = 10,

        // the maximum number of query string parameters to accept.
        // Additional parameters will be silently ignored.
        max_query_count: usize = 32,
    }
    // various options for tweaking response object
    .response = .{
        // Minimum number of response objects to keep pooled
        // This should be set to the same value as request.pool_size
        pool_size: usize = 100,
        
        // The maximum number of headers to accept. 
        // Additional headers will be silently ignored.
        max_header_count: usize = 16,
    }
});
```

# Zig Compatibility
0.11-dev is constantly changing, but the goal is to keep this library compatible with the latest development release. Since 0.11-dev does not support async, threads are currently and there are some thread-unsafe code paths. Since this library is itself a WIP, the entire thing is considered good enough for playing/testing, and should be stable when 0.11 itself becomes more stable.

# HTTP Compliance
This implementation may never be fully HTTP/1.1 compliant, as it is built with the assumption that it will sit behind a reverse proxy that is tolerant of non-compliant upstreams (e.g. nginx). 
