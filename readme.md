An HTTP/1.1 server for Zig.

## Demo
http.zig powers the <https://www.aolium.com> [api server](https://github.com/karlseguin/aolium-api).

# Installation
This library supports native Zig module (introduced in 0.11). Add a "httpz" dependency to your `build.zig.zon`.

## Async, Threads, Scale
Until async support is re-added to Zig, this library is using a stopgap approach for concurrency. 

In the master branch, a naive thread-per-connection is used. This approach is straightforward and simple to reason about. Despite using a pool of objects, this approach can still cause unpredictable memory spikes due to the overhead of the threads themselves. Plus, performance can be hurt due to thread thrashing.

As a simple alternative, the `thread_pool = #` configuration value can be set which will use an `std.Thread.Pool`. This will make memory usage predictable and can result in better performance.

If your system has access to poll(2) (e.g. Linux, BSD, MacOS), you can also try the [thread_pool](https://github.com/karlseguin/http.zig/tree/thread_pool) branch. This uses a custom thread pool, and poll(2) for better concurrency. It also supports additional timeout configurations (though, ideally, you leave them disabled and set timeouts in your reverse proxy).

# Usage

## Simple Use Case
The library supports both simple and complex use cases. A simple use case is shown below. It's initiated by the call to `httpz.Server()`:

```zig
const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try httpz.Server().init(allocator, .{.port = 5882});
    
    // overwrite the default notFound handler
    server.notFound(notFound);

    // overwrite the default error handler
    server.errorHandler(errorHandler); 

    var router = server.router();

    // use get/post/put/head/patch/options/delete
    // you can also use "all" to attach to all methods
    router.get("/api/user/:id", getUser);

    // start the server in the current thread, blocking.
    try server.listen(); 
}

fn getUser(req: *httpz.Request, res: *httpz.Response) !void {
    // status code 200 is implicit. 

    // The json helper will automatically set the res.content_type = httpz.ContentType.JSON;
    // Here we're passing an inferred anonymous structure, but you can pass anytype 
    // (so long as it can be serialized using std.json.stringify)

    try res.json(.{.id = req.param("id").?, .name = "Teg"}, .{});
}

fn notFound(_: *httpz.Request, res: *httpz.Response) !void {
    res.status = 404;

    // you can set the body directly to a []u8, but note that the memory
    // must be valid beyond your handler. Use the res.arena if you need to allocate
    // memory for the body.
    res.body = "Not Found";
}

// note that the error handler return `void` and not `!void`
fn errorHandler(req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
    res.status = 500;
    res.body = "Internal Server Error";
    std.log.warn("httpz: unhandled exception for request: {s}\nErr: {}", .{req.url.raw, err});
}
```

## Complex Use Case 1 - Shared Global Data
The call to `httpz.Server()` is a wrapper around the more powerful `httpz.ServerCtx(G, R)`. `G` and `R` are types. `G` is the type of the global data `R` is the type of per-request data. For this use case, where we only care about shared global data, we'll make G == R:

```zig
const std = @import("std");
const httpz = @import("httpz");

const Global = struct {
    hits: usize = 0,
    l: std.Thread.Mutex = .{},
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global = Global{};
    var server = try httpz.ServerCtx(*Global, *Global).init(allocator, .{}, &global);
    var router = server.router();
    router.get("/increment", increment);
    return server.listen();
}

fn increment(global: *Global, _: *httpz.Request, res: *httpz.Response) !void {
    global.l.lock();
    const hits = global.hits + 1;
    global.hits = hits;
    global.l.unlock();

    // or, more verbosse: httpz.ContentType.TEXT
    res.content_type = .TEXT;
    var out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
    res.body = out;
}
```

There are a few important things to notice. First, the `init` function of `ServerCtx(G, R)` takes a 3rd parameter: the global data. Second, our actions take a new parameter of type `G`. Any custom notFound handler (set via `server.notFound(...)`) or error handler(set via `server.errorHandler(errorHandler)`) must also accept this new parameter. 

Because the new parameter is first, and because of how struct methods are implemented in Zig, the above can also be written as:

```zig
const std = @import("std");
const httpz = @import("httpz");

const Global = struct {
    hits: usize = 0,
    l: std.Thread.Mutex = .{},

    fn increment(global: *Global, _: *httpz.Request, res: *httpz.Response) !void {
        global.l.lock();
        var hits = global.hits + 1;
        global.hits = hits;
        global.l.unlock();

        res.content_type = .TEXT;
        var out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
        res.body = out;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global = &Global{};
    var server = try httpz.ServerCtx(*Global, *Global).init(allocator, .{}, global);
    var router = server.router();
    router.get("/increment", global.increment);
    return server.listen();
}
```

It's up to the application to make sure that access to the global data is synchronized.

## Complex Use Case 2 - Custom Dispatcher
While httpz doesn't support traditional middleware, it does allow applications to provide their own custom dispatcher. This gives an application full control over how a request is processed. 

To understand what the dispatcher does and how to write a custom one, consider the default dispatcher which looks something like:

```zig
fn dispatcher(global: G, action: httpz.Action(R), req: *httpz.Request, res: *httpz.Response) !void {
    // this is how httpz maintains a simple interface when httpz.Server()
    // is used instead of httpz.ServerCtx(G, R)
    if (R == void) {
        return action(req, res);
    }
    return action(global, req, res);
}
```

The default dispatcher merely calls the supplied `action`. A custom dispatch could time and log each request, apply filters to the request and response and do any middleware-like behavior before, after or around the action. Of note, the dispatcher doesn't have to call `action`.

The dispatcher can be set globally and/or per route

```zig
var server = try httpz.Server().init(allocator, .{});

// set a global dispatch for any routes defined from this point on
server.dispatcher(mainDispatcher); 

// set a dispatcher for this route
// note the use of "deleteC" the "C" is for Configuration and is used
// since Zig doesn't have overloading or optional parameters.
server.router().deleteC("/v1/session", logout, .{.dispatcher = loggedIn}) 
...

fn mainDispatcher(action: httpz.Action(void), req: *httpz.Request, res: *httpz.Response) !void {
    res.header("cors", "isslow");
    return action(req, res);
}

fn loggedIn(action: httpz.Action(void), req: *httpz.Request, res: *httpz.Response) !void {
    if (req.header("authorization")) |_auth| {
        // TODO: make sure "auth" is valid!
        return mainDispatcher(action, req, res);
    }
    res.status = 401;
    res.body = "Not authorized";
}

fn logout(req: *httpz.Request, res: *httpz.Response) !void {
    ...
}
```

See [router groups](#groups) for a more convenient approach to defining a dispatcher for a group of routes.

## Complex Use Case 3 - Route-Based Global Data
Much like the custom dispatcher explained above, global data can be specified per-route:

```zig
var server = try httpz.ServerCtx(*Global, *Global).init(allocator, .{}, &default_global);

var router = server.router();
server.router().deleteC("/v1/session", logout, .{.ctx = &Global{...}});
```

See [router groups](#groups) for a more convenient approach to defining global dta for a group of routes.

## Complex Use Case 4 - Per-Request Data
We can combine what we've learned from the above two uses cases and use `ServerCtx(G, R)` where `G != R`. In this case, a dispatcher **must** be provided (failure to provide a dispatcher will result in 500 errors). This is because the dispatcher is needed to generate `R`.

```zig
const std = @import("std");
const httpz = @import("httpz");

const Global = struct {
    hits: usize = 0,
    l: std.Thread.Mutex = .{},
};

const Context = struct {
    global: *Global,
    user_id: ?[]const u8,
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global = Global{};

    var server = try httpz.ServerCtx(*Global, Context).init(allocator, .{}, &global);

    // set a global dispatch for any routes defined from this point on
    server.dispatcher(dispatcher); 

    // again, it's possible to had per-route dispatchers
    server.router().delete("/v1/session", logout) 
...

fn dispatcher(global: *Global, action: httpz.Action(Context), req: *httpz.Request, res: *httpz.Response) !void {
    // If needed, req.arena is an std.mem.Allocator than can be used to allocate memory
    // and it'll exist for the life of this request.

    const context = Context{
        .global = global,

        // we shouldn't blindly trust this header!
        .user_id = req.header("user"),
    }
    return action(context, contextreq, res);
}

fn logout(context: Context, req: *httpz.Request, res: *httpz.Response) !void {
    ...
}
```

The per-request data, `Context` in the above example, is the first parameter and thus actions can optionally be called as methods on the structure.

## httpz.Request
The following fields are the most useful:

* `method` - an httpz.Method enum
* `arena` - an arena allocator that will be reset at the end of the request
* `url.path` - the path of the request (`[]const u8`)
* `address` - the std.net.Address of the client

### Path Parameters
The `param` method of `*Request` returns an `?[]const u8`. For example, given the following path:

```zig
router.get("/api/users/:user_id/favorite/:id", user.getFavorite, .{});
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
router.put("/api/users/:user_id/favorite/:id", user.updateFavorite, .{});

// currently logged in user, maybe?
router.put("/api/use/favorite/:id", user.updateFavorite, .{});
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

#### Json Body
The `req.json(TYPE)` function is a wrapper around the `body()` function which will call `std.json.parse` on the body. This function does not consider the content-type of the request and will try to parse any body.

```zig
if (try req.json(User)) |user| {

}
```

#### JsonValueTree Body
The `req.jsonValueTree()` function is a wrapper around the `body()` function which will call `std.json.Parse` on the body, returning a `!?std.jsonValueTree`. This function does not consider the content-type of the request and will try to parse any body.

```zig
if (try req.jsonValueTree()) |t| {
    // probably want to be more defensive than this
    const product_type = r.root.Object.get("type").?.String;
    //...
}
```

#### JsonObject Body
The even more specific `jsonObject()` function will return an `std.json.ObjectMap` provided the body is a map

```zig
if (try req.jsonObject()) |t| {
    // probably want to be more defensive than this
    const product_type = t.get("type").?.String;
    //...
}
```

## httpz.Response
The following fields are the most useful:

* `status` - set the status code, by default, each response starts off with a 200 status code
* `content_type` - an httpz.ContentType enum value. This is a convenience and optimization over using the `res.header` function.
* `body` - set the body to an explicit []const u8. The memory address pointed to by this value must be valid beyond the action handler. The `arena` field can help for dynamic values
* `arena` - an arena allocator that will be reset at the end of the request

## JSON
The `json` function will set the content_type to `httpz.ContentType.JSON` and serialize the provided value using `std.json.stringify`. The 2nd argument to the json function is the `std.json.StringifyOptions` to pass to the `stringify` function.

Because the final size of the serialized object cannot be known ahead of a time, a custom writer is used. Initially, this writer will use a static buffer defined by the `config.response.body_buffer_size`. However, as the object is being serialized, if this static buffer runs out of space, a dynamic buffer will be allocated and the static buffer will be copied into it (at this point, the dynamic buffer essentially behaves like an `ArrayList(u8)`.

As a general rule, I'd suggest making sure `config.response.body_buffer_size` is large enough to fit 99% of your responses. As an alternative, you can always manage your own serialization and simply set the `res.content_type` and `res_body` fields.

## Dynamic Content
Besides helpers like `json`, you can use the `res.arena` to create dynamic content:

```zig
const query = try req.query();
const name = query.get("name") orelse "stranger";
var out = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
res.body = out;
```

## Chunked Response
You can send a chunked response using `res.chunk(DATA)`. Chunked responses do not include a `Content-Length` so do need to be fully buffered in memory before sending. Multiple calls to `res.chunk` are, of course, supported. However, the response status along with any header, must be set before the first call to `chunk`:

```zig
res.status = 200;
res.header("A", "Header");
res.content_type = httpz.ContentType.TEXT;

try res.chunk("This is a chunk");
try res.chunk("\r\n");
try res.chunk("And another one");
```

## io.Writer
`res.writer()` returns an `std.io.Writer`. Various types support writing to an io.Writer. For example, the built-in JSON stream writer can use this writer:

```zig
var ws = std.json.writeStream(res.writer(), 4);
try ws.beginObject();
try ws.objectField("name");
try ws.emitString(req.param("name").?);
try ws.endObject();
```

See the `json` function for an explanation on how this writer behaves.

## Header Value
Set header values using the `res.header(NAME, VALUE) function`:

```zig
res.header("Location", "/");
```

The header name and value are sent as provided.

## Explicit Write
Internally, when the dispatcher returns (whether it be an internal/default dispatcher or an application-specific dispatcher), `res.write()` is called to
write the response to the socket. 

It is safe to call `res.write()` directly from the application. This is absolutely not necessary in normal cases. One case where this could be needed is if the data for the response (say the body) only exists within the application's handler (and the `res.arena` cannot be used).

`res.write()` is safe to call because of the `res.written` boolean flag. Once called, `res.written` is set to true and subsequent calls to `res.write()` are ignored. Thus, an even more advanced use case is for the application to set `res.written` directly.

While explicit use of `res.write()` is uncommon, I can think of no reason to to call `res.write()` when `res.chunk([]const u8)` is used. This is not supported.

## Router
You can use the `get`, `put`, `post`, `head`, `patch`, `trace`, `delete` or `options` method of the router to define a router. You can also use the special `all` method to add a route for all methods.

These functions can all `@panic` as they allocate memory. Each function has an equivalent `tryXYZ` variant which will return an error rather than panicking:

```zig
// this can panic if it fails to create the route
router.get("/", index);

// this returns a !void (which you can try/catch)
router.tryGet("/", index);
```

There is also a `getC` and `tryGetC` (and `putC` and `tryPutC`, and ...) that takes a 3rd parameter: the route configuration. Most of the time, this isn't needed. So, to streamline usage and given Zig's lack of overloading or default parameters, these awkward `xyzC` functions were created. Currently, the only route configuration value is to set a custom dispatcher for the specific route.
 See [Custom Dispatcher](#complex-use-case-2---custom-dispatcher) for more information.

### Groups
Defining a custom dispatcher or custom global data on each route can be tedious. Instead, consider using a router group:

```zig
var admin_routes = router.group("/admin", .{.dispatcher = custom_admin_dispatcher, .ctx = custom_admin_data});
admin_routes.get("/users", listUsers);
admin_routs.delete("/users/:id", deleteUsers);
```

The first parameter to `group` is a prefix to prepend to each route in the group. An empty prefix is acceptable.

The second paremeter is the same configuration object given to the `getC`, `putC`, etc. routing variants. All configuration values are optional and, if omitted, the default configured value will be used.

### Casing
You **must** use a lowercase route. You can use any casing with parameter names, as long as you use that same casing when getting the parameter.

### Parameters
Routing supports parameters, via `:CAPTURE_NAME`. The captured values are available via `req.params.get(name: []const u8) ?[]const u8`.  

### Glob
You can glob an individual path segment, or the entire path suffix. For a suffix glob, it is important that no trailing slash is present.

```zig
// prefer using `server.notFound(not_found)` than a global glob.
router.all("/*", not_found, .{});
router.get("/api/*/debug", .{})
```

When multiple globs are used, the most specific will be selected. E.g., give the following two routes:

```zig
router.get("/*", not_found, .{});
router.get("/info/*", any_info, .{})
```

A request for "/info/debug/all" will be routed to `any_info`, whereas a request for "/over/9000" will be routed to `not_found`.


### Limitations
The router has several limitations which might not get fixed. These specifically resolve around the interaction of globs, parameters and static path segments.

Given the following routes:

```zig
router.get("/:any/users", route1, .{});
router.get("/hello/users/test", route2, .{});
```

You would expect a request to "/hello/users" to be routed to `route1`. However, no route will be found. 

Globs interact similarly poorly with parameters and static path segments.

Resolving this issue requires keeping a stack (or visiting the routes recursively), in order to back-out of a dead-end and trying a different path.
This seems like an unnecessarily expensive thing to do, on each request, when, in my opinion, such route hierarchies are quite uncommon. 

## CORS
CORS requests can be satisfied through normal use of routing and response headers. However, for common cases, httpz can satisfy CORS requests directly by passing a `cors` object in the configuration. By default, the `cors` field is null and httpz will handle CORS request like any other.

When the `cors` object is set, the `origin` field must also be set. httpz will include an `Access-Control-Allow-Origin` header in every response. The configuration `headers`, `methods` and `max_age` can also be set in order to set the corresponding headers on a preflight request.

```zig
var srv = Server().init(allocator, .{.cors = .{
    .origin = "httpz.local",
    .headers = "content-type",
    .methods = "GET,POST",
    .max_age = "300"
}}) catch unreachable;
```

Only the `origin` field is required. The values given to the configuration are passed as-is to the appropriate preflight header.

## Configuration
The third option given to `listen` is an `httpz.Config` instance. Possible values, along with their default, are:

```zig
try httpz.listen(allocator, &router, .{
    // the port to listen on
    .port = 5882, 

    // the interface address to bind to
    .address = "127.0.0.1",

    // unix socket to listen on (mutually exlusive with host&port)
    .unix_path = null,

    // configure the pool of request/response object pairs
    .pool = .{
        // number of items to keep in the pool at all times.
        .min = 20,

        // maximum number of items to create
        .max = 500,

        // time, in millisecond, to wait for an item to be available
        .timeout = 5000,
    },

    // defaults to null
    .cors = {
        .origin: []const u8,  // required if cors is passed
        .headers: ?[]const u8,
        .methods: ?[]const u8,
        .max_age: ?[]const u8,
    },

    // various options for tweaking request processing
    .request = .{
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
        .buffer_size: usize = 65_536,

        // The maximum number of headers to accept. 
        // Additional headers will be silently ignored.
        .max_header_count: usize = 32,

        // the maximum number of URL parameters to accept.
        // Additional parameters will be silently ignored.
        .max_param_count: usize = 10,

        // the maximum number of query string parameters to accept.
        // Additional parameters will be silently ignored.
        .max_query_count: usize = 32,
    }
    // various options for tweaking response object
    .response = .{
        // Used to buffer the response header.
        // This MUST be at least as big as your largest individual header+value+4
        // (the +4 is for for the colon+space and the \r\n)
        .header_buffer_size: usize = 4096,

        // Used to buffer dynamic responses. If the response body is larger than this
        // value, a dynamic buffer will be allocated. It's possible to set this to 0,
        // but this should only be done if the overwhelming majority of responses
        // are set directly using res.body = "VALUE"; and not a dynamic response
        // generator like res.json(..);
        .body_buffer_size: usize = 32_768,

        // The maximum number of headers to accept. 
        // Additional headers will be silently ignored.
        .max_header_count: usize = 16,
    }
});
```

`pool.min * (request.buffer_size + response.body_buffer_size + response.header_buffer_size)` is the minimum amount of memory this library will use (plus various overhead, but that should be relatively small in comparison).

`pool.max * (request.max_body_size + response.body_buffer_size + response.header_buffer_size)` is the maximum amount of memory this library will use (plus various overhead, but that should be relatively small in comparison).

Systems with memory to spare will benefit by using buffers large enough for their typical request and response bodies. Pool configuration is more complicated, especially given the (current) threaded-nature of the system and keepalive. Using a relatively small (e.g. # of cores) `pool.min` and `pool.max` would yield the highest performance (due to having less contention), but because of keepalive, that can easily result in running out of available pooled items (which results in a 503 error). 

# Testing
The `httpz.testing` namespace exists to help application developers setup `*httpz.Requests` and assert `*httpz.Responses`.

Imagine we have the following partial action:

```zig
fn search(req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const search = query.get("search") orelse return missingParameter(res, "search");

    // TODO ...
}

fn missingParameter(res: *httpz.Response, parameter: []const u8) !void {
    res.status = 400;
    return res.json(.{.@"error" = "missing parameter", .parameter = parameter}, .{});
}
```

We can test the above error case like so:

```zig
const ht = @import("httpz").testing;

test "search: missing parameter" {
    // init takes the same Configuration used when creating the real server
    // but only the config.request and config.response settings have any impact
    var web_test = ht.init(.{});
    defer web_test.deinit();

    try search(web_test.req, web_test.res);
    try web_test.expectStatus(400);
    try web_test.expectJson(.{.@"error" = "missing parameter", .parameter = "search"});
}
```

## Building the test Request
The testing structure returns from <code>httpz.testing.init</code> exposes helper functions to set param, query and query values as well as the body:

```zig
var web_test = ht.init(.{});
defer web_test.deinit();

web_test.param("id", "99382");
web_test.query("search", "tea");
web_test.header("Authorization", "admin");

web_test.body("over 9000!");
// OR
web_test.json(.{.over = 9000});

// at this point, web_test.req has a param value, a query string value, a header value and a body.
```

As an alternative to the `query` function, the full URL can also be set. If you use `query` AND `url`, the query parameters of the URL will be ignored:

```zig
web_test.url("/power?over=9000");
```

## Asserting the Response
There are various methods to assert the response:

```zig
try web_test.expectStatus(200);
try web_test.expectHeader("Location", "/");
try web_test.expectHeader("Location", "/");
try web_test.expectBody("{\"over\":9000}");
```

If the expected body is in JSON, there are two helpers available. First, to assert the entire JSON body, you can use `expectJson`:

```zig
try web_test.expectJson(.{.over = 9000});
```

Or, you can retrieve a `std.json.Value` object by calling `getJson`:

```zig
const json = try web_test.getJson();
try std.testing.expectEqual(@as(i64, 9000), json.Object.get("over").?.Integer);
```

For more advanced validation, use the `parseResponse` function to return a structure representing the parsed response:

```zig
const res = try web_test.parsedResponse();
try std.testing.expectEqual(@as(u16, 200), res.status);
// use res.body for a []const u8  
// use res.headers for a std.StringHashMap([]const u8)
// use res.raw for the full raw response
```

# Zig Compatibility
0.12-dev is constantly changing, but the goal is to keep this library compatible with the latest development release. Since 0.12-dev does not support async, threads are currently used. Since this library is itself a WIP, the entire thing is considered good enough for playing/testing, and should be stable when 0.12 itself becomes more stable.

# HTTP Compliance
This implementation may never be fully HTTP/1.1 compliant, as it is built with the assumption that it will sit behind a reverse proxy that is tolerant of non-compliant upstreams (e.g. nginx). (One example I know of is that the server doesn't include the mandatory Date header in the response.)

# Server Side Events
Service Side Events can be enabled by calling `res.startEventStream()`. On success, this will return an `httpz.Stream` (which is a `std.net.Stream` or a mock object during testing). The stream will remain valid for the duration of the action, but `req` and `res` should no longer be used. `res.body` must not be set (directly or indirectly) prior to calling `startEventStream`.

```zig
// Can set headers
res.header("Custom-Header", "Custom-Value");

const stream = res.startEventStream();
// do not use res or req from this point on
while (true) {
    // some event loop
    try stream.writeAll("event: ....");
}
```

# websocket.zig
I'm also working on a websocket server implementation for zig: [https://github.com/karlseguin/websocket.zig](https://github.com/karlseguin/websocket.zig).
