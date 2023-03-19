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

    // use get/post/put/head/patch/options/delete
    // you can also use "all" to attach to all methods
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
The following fields are the most useful:

* `method` - an httpz.Method enum
* `arena` - an arena allocator that will be reset at the end of the request
* `url.path` - the path of the request (`[]const u8`)

### Path Parameters
The `param` method of `*Request` returns an `?[]const u8`. For example, given the following path:

```zig
try router.get("/api/users/:user_id/favorite/:id", user.getFavorite);
```

Then we could access the `user_id` and `id` via:

```zig
pub fn getFavorite(req *http.Request, res: *http.Response) !void {
    const user_id = req.param("user_id").?;
    const favorite_id = req.param("id").?;
    ...
```

In the above, passing any other value to `param` would return a null object (since the route associated with `getFavorite` only defines these 2 parameters). Given that routes are generally statically defined, it should not be possible for `req.param` to return an unexpected null. However, it *is* possible to define two routes to the same action:

```zig
try router.put("/api/users/:user_id/favorite/:id", user.updateFavorite);

// currently logged in user, maybe?
try router.put("/api/use/favorite/:id", user.updateFavorite);
```

In which case the optional return value of `param` might be useful.

### Header Values
Similar to `param`, header values can be fetched via the `header` function, which also returns a `?[]const u8`:

```zig
if (req.header("authorization")) |auth| {

} else { 
    // not logged in?:
}
```

Header names are lowercase. Values maintain their original casing.

### QueryString
The framework does not automatically parse the query string. Therefore, its API is slightly different.

```zig
const query = try req.query();
if (query.get("search")) |search| {

} else {
    // no search parameter
};
```

On first call, the `query` function attempts to parse the querystring. This requires memory allocations to unescape encoded values. The parsed value is internally cached, so subsequent calls to `query()` are fast and cannot fail.

The original casing of both the key and the name are preserved.

### Body
The body works like the querystring. It isn't automatically read from the socket and thus the initial call to `body()` can fail:

```zig
if (try req.body()) |body| {

}
```

Like `query`, the body is internally cached and subsequent calls are fast and cannot fail. If there is no body, `body()` returns null.


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
        // Similar to request.buffer_size, but is currently only used for
        // buffering the header (unlike the request one which CAN be used for
        // body as well). This MUST be at least as big as your largest
        // individual header+value (+4 for the colon+space and the \r\n)
        buffer_size: usize = 4096,

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
