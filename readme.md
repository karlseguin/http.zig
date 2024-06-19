# An HTTP/1.1 server for Zig.

## Demo
http.zig is used by [logdk](https://github.com/karlseguin/logdk), my log aggregator. You can see a [live demo here](https://logdk.goblgobl.com/).

# Installation
This library supports native Zig module (introduced in 0.11). Add a "httpz" dependency to your `build.zig.zon`. This library only imports [websocket.zig](https://github.com/karlseguin/websocket.zig) and [metrics.zig](https://github.com/karlseguin/metrics.zig) - two libraries that I've written which have no other dependencies.

# Alternatives
If you're looking for a higher level web framework with more included functionality, consider [JetZig](https://www.jetzig.dev/) which is built on top of httpz.

# Why not std.http.Server
`std.http.Server` is slow. Exactly how slow depends on what you're doing and how you're testing. There are many Zig HTTP server implementations. Most wrap `std.http.Server` and tend to be slow; slower than Sinatra. A few wrap some C libraries and are much faster (though some of these are slow too!). http.zig is written in Zig, without using `std.http.Server`. On an M2, a basic request can hit 110K requests per seconds.

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
    res.body = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
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
        const hits = global.hits + 1;
        global.hits = hits;
        global.l.unlock();

        res.content_type = .TEXT;
        res.body = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
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
    const context = Context{
        .global = global,

        // we shouldn't blindly trust this header!
        .user_id = req.header("user"),
    }
    return action(context, req, res);
}

fn logout(context: Context, req: *httpz.Request, res: *httpz.Response) !void {
    ...
}
```

The per-request data, `Context` in the above example, is the first parameter and thus actions can optionally be called as methods on the structure.

`server.undefinedDispatcher()` can be used to generate a dispatcher which passes `undefined` R. This is dangerous, but can be useful if you have a few routes, such as `/ping`, which you want to skip your main dispatcher.

```zig
router.getC("/metrics", metrics, .{.dispatcher = server.dispatchUndefined()});

...
pub fn metrics(_: Context, _: *httpz.Request, res: *httpz.Response) !void {
    // The first parameter, our Context, is `undefined`
    const writer = res.writer();
    try httpz.writeMetrics(writer);
}
```

## Complex Use Case 5 - Dispatch Takeover
As shown above, a custom dispatcher receives the action to execute as well as a request and response object. Obviously, in order to provide the action, httpz must have already matched the request with a route. Advanced cases might wish to circumvent httpz's router and take over the request and response object as early as possible. This can be achieved by providing a dispatcher with a public `handle` method:

```zig

const Dispatcher = struct {
    fn handle(_: Dispatcher, req: *Request, res: *Response) void {
        // todo
    }
};

var server = try ServerCtx(Dispatcher, Dispatcher).init(allocator, config, Dispatcher{});
...
```

When used this way, httpz's routing, action error handling (hence why `handle` can't return an errorset), not found fallback and CORS handling are all bypassed.

# Memory and Arenas
Any allocations made for the response, such as the body or a header, must remain valid until **after** the action returns. To achieve this, use `res.arena` or the `res.writer()`:

```zig
fn arenaExample(req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const name = query.get("name") orelse "stranger";
    res.body = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
}

fn writerExample(req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const name = query.get("name") orelse "stranger";
    try std.fmt.format(res.writer(), "Hello {s}", .{name});
}
```

Alternatively, you can explicitly call `res.write()`.

## httpz.Request
The following fields are the most useful:

* `method` - an httpz.Method enum
* `arena` - an allocator that is valid until the end of the action handler. This arena can be much faster than using res.arena, but cannot be used for any part of the response.
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

To iterate over all headers, use:

```zig
const headers = req.headers;
for (headers.keys[0..headers.len], headers.values[0..headers.len]) |name, value| {
    
}
```

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

To iterate over all query parameters, use:

```zig
const qs = req.qs;
for (qs.keys[0..qs.len], qs.values[0..qs.len]) |name, value| {
    
}
```

### Body
The body of the request, if any, can be accessed using `req.body()`. This returns a `?[]const u8`.

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

### Form Data
The body of the request, if any, can be parsed as a "x-www-form-urlencoded "value  using `req.formData()`. The `request.max_form_count` configuration value must be set to the maximum number of form fields to support. This defaults to 0.

This behaves similarly to `query()`.

On first call, the `formData` function attempts to parse the body. This can require memory allocations to unescape encoded values. The parsed value is internally cached, so subsequent calls to `formData()` are fast and cannot fail.

The original casing of both the key and the name are preserved.

To iterate over all fields, use:

```zig
const fd = try req.formData();
for (fd.keys[0..fd.len], fd.values[0..fd.len]) |name, field| {
    //
}
```

Once this function is called, `req.multiFormData()` will no longer work (because the body is assumed parsed).

### Multi Part Form Data
Similar to the above, `req.multiFormData()` can be called to parse requests with a "multipart/form-data" content type. The `request.max_multiform_count` configuration value must be set to the maximum number of form fields to support. This defaults to 0.

This is a different API than `formData` because the return type is different. Rather than a simple string=>value type, the multi part form data value consists of a `value: []const u8` and a `filename: ?[]const u8`.

On first call, the `multiFormData` function attempts to parse the body. The parsed value is internally cached, so subsequent calls to `multiFormData()` are fast and cannot fail.

The original casing of both the key and the name are preserved.

To iterate over all fields, use:

```zig
const fd = try req.multiFormData();
for (fd.keys[0..fd.len], fd.values[0..fd.len]) |name, field| {
    // access the value via field.value
    // and field.filename (an optional)
}
```

Once this function is called, `req.formData()` will no longer work (because the body is assumed parsed).

Advance warning: This is one of the few methods that can modify the request in-place. For most people this won't be an issue, but if you use `req.body()` and `req.multiFormData()`, say to log the raw body, the content-disposition field names are escaped in-place. It's still save to use `req.body()` but any  content-disposition name that was escaped will be a little off.

## httpz.Response
The following fields are the most useful:

* `status` - set the status code, by default, each response starts off with a 200 status code
* `content_type` - an httpz.ContentType enum value. This is a convenience and optimization over using the `res.header` function.
* `arena` - an arena allocator that will be reset at the end of the request

### Body
The simplest way to set a body is to set `res.body` to a `[]const u8`. **However** the provided value must remain valid until the body is written, which happens outside of your application code.

Therefore, `res.body` can be safely used with constant strings. It can also be used with content created with `res.arena` (explained in the next section).


### Dynamic Content
You can use the `res.arena` allocator to create dynamic content:

```zig
const query = try req.query();
const name = query.get("name") orelse "stranger";
res.body = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
```

Memory allocated with `res.arena` will exist until the response is sent.

### io.Writer
`res.writer()` returns an `std.io.Writer`. Various types support writing to an io.Writer. For example, the built-in JSON stream writer can use this writer:

```zig
var ws = std.json.writeStream(res.writer(), 4);
try ws.beginObject();
try ws.objectField("name");
try ws.emitString(req.param("name").?);
try ws.endObject();
```

Initially, writes will go to a pre-allocated buffer defined by `config.response.body_buffer_size`. If the buffer becomes full, a larger buffer will either be fetched from the large buffer pool (`config.workers.large_buffer_count`) or dynamically allocated.

### JSON
The `res.json` function will set the content_type to `httpz.ContentType.JSON` and serialize the provided value using `std.json.stringify`. The 2nd argument to the json function is the `std.json.StringifyOptions` to pass to the `stringify` function.

This function uses `res.writer()` explained above.

### Header Value
Set header values using the `res.header(NAME, VALUE)` function:

```zig
res.header("Location", "/");
```

The header name and value are sent as provided. Both the name and value must remain valid until the response is sent, which will happen outside of the action. Dynamic names and/or values should be created and or dupe'd with `res.arena`. 

`res.headerOpts(NAME, VALUE, OPTS)` can be used to dupe the name and/or value:

```zig
try res.headerOpts("Location", location, .{.dupe_value = true});
```

`HeaderOpts` currently supports `dupe_name: bool` and `dupe_value: bool`, both default to `false`.

### Writing
By default, httpz will automatically flush your response. In more advance cases, you can use `res.write()` to explicitly flush it. This is useful in cases where you have resources that need to be freed/released only after the response is written. For example, my [LRU cache](https://github.com/karlseguin/cache.zig) uses atomic referencing counting to safely allow concurrent access to cached data. This requires callers to "release" the cached entry:

```zig
pub fn info(app: *MyApp, _: *httpz.Request, res: *httpz.Response) !void {
    const cached = app.cache.get("info") orelse {
        // load the info
    };
    defer cached.release();

    res.body = cached.value;
    res.write();
}
```

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

The second parameter is the same configuration object given to the `getC`, `putC`, etc. routing variants. All configuration values are optional and, if omitted, the default configured value will be used.

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
This seems like an unnecessarily expensive thing to do, on each request, when, in my opinion, such route hierarchies are uncommon. 

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
The third option given to `listen` is an `httpz.Config` instance. When running in <a href=#blocking-mode>blocking mode</a> (e.g. on Windows) a few of these behave slightly, but not drastically, different.

Possible values, along with their default, are:

```zig
try httpz.listen(allocator, &router, .{
    // Port to listen on
    .port = 5882, 

    // Interface address to bind to
    .address = "127.0.0.1",

    // unix socket to listen on (mutually exclusive with host&port)
    .unix_path = null,

    // configure the workers which are responsible for:
    // 1 - accepting connections
    // 2 - reading and parsing requests
    // 3 - passing requests to the thread pool
    .workers = .{
        // Number of worker threads
        // (blocking mode: handled differently)
        .count = 2,

        // Maximum number of concurrent connection each worker can handle
        // (blocking mode: currently ignored)
        .max_conn = 500,

        // Minimum number of connection states each worker should maintain
        // (blocking mode: currently ignored)
        .min_conn = 32,

        // A pool of larger buffers that can be used for any data larger than configured
        // static buffers. For example, if response headers don't fit in in 
        // $response.header_buffer_size, a buffer will be pulled from here.
        // This is per-worker. 
        .large_buffer_count = 16,

        // The size of each large buffer.
        .large_buffer_size = 65536,

        // Size of bytes retained for the connection arena between use. This will
        // result in up to `min_conn * retain_allocated_bytes` of memory usage.
        .retain_allocated_bytes = 4096,
    },

    // configures the threadpool which processes requests. The threadpool is 
    // where your application code runs.
    .thread_pool = .{
        // Number threads. If you're handlers are doing a lot of i/o, a higher
        // number might provide better throughput
        // (blocking mode: handled differently)
        .count = 4,

        // The maximum number of pending requests that the thread pool will accept
        // This applies back pressure to the above workers and ensures that, under load
        // pending requests get precedence over processing new requests.
        .backlog = 500,

        // Size of the static buffer to give each thread. Memory usage will be 
        // `count * buffer_size`. If you're making heavy use of either `req.arena` or
        // `res.arena`, this is likely the single easiest way to gain performance. 
        .buffer_size = 8192,
    },

    // defaults to null
    .cors = {
        .origin: []const u8,  // required if cors is passed
        .headers: ?[]const u8,
        .methods: ?[]const u8,
        .max_age: ?[]const u8,
    },

    // options for tweaking request processing
    .request = .{
        // Maximum body size that we'll process. We can allocate up 
        // to this much memory per request for the body. Internally, we might
        // keep this memory around for a number of requests as an optimization.
        // So the maximum amount of memory that our request pool will use is in
        // the neighborhood of pool_size * max_body_size, but this value should be temporary
        // (there are more allocations, but this is the biggest chunk).
        max_body_size: usize = 1_048_576,

        // This memory is allocated upfront. The request header _must_ fit into
        // this space, else the request will be rejected.
        .buffer_size: usize = 32_768,

        // Maximum number of headers to accept. 
        // Additional headers will be silently ignored.
        .max_header_count: usize = 32,

        // Maximum number of URL parameters to accept.
        // Additional parameters will be silently ignored.
        .max_param_count: usize = 10,

        // Maximum number of query string parameters to accept.
        // Additional parameters will be silently ignored.
        .max_query_count: usize = 32,

        // Maximum number of x-www-form-urlencoded fields to support.
        // Additional parameters will be silently ignored. This must be
        // set to a value greater than 0 (the default) if you're going
        // to use the req.formData() method.
        .max_form_count: usize = 0,

        // Maximum number of multipart/form-data fields to support.
        // Additional parameters will be silently ignored. This must be
        // set to a value greater than 0 (the default) if you're going
        // to use the req.multiFormData() method.
        .max_multiform_count: usize = 0,
    },

    // options for tweaking response object
    .response = .{
        // The maximum number of headers to accept. 
        // Additional headers will be silently ignored.
        .max_header_count: usize = 16,
    },

    .timeout = .{
        // Time in seconds that keepalive connections will be kept alive while inactive
        .keepalive = null,

        // Time in seconds that a connection has to send a complete request
        .request = null

        // Maximum number of a requests allowed on a single keepalive connection
        .request_count = null,
    },
    .websocket = .{
        // refer to https://github.com/karlseguin/websocket.zig#config
        max_size: usize = 65536,
        buffer_size: usize = 4096,
        handle_ping: bool = false,
        handle_pong: bool = false,
        handle_close: bool = false,
        large_buffer_pool_count: u16 = 8,
        large_buffer_size: usize = 32768,
    },
});
```

### Timeouts
The configuration settings under the `timeouts` section are designed to help protect the system against basic DOS attacks (say, by connecting and not sending data). However it is recommended that you leave these null (disabled) and use the appropriate timeout in your reverse proxy (e.g. NGINX). 

The `timeout.request` is the time, in seconds, that a connection has to send a complete request. The `timeout.keepalive` is the time, in second, that a connection can stay connected without sending a request (after the initial request has been sent).

The connection alternates between these two timeouts. It starts with a timeout of `timeout.request` and after the response is sent and the connection is placed in the "keepalive list", switches to the `timeout.keepalive`. When new data is received, it switches back to `timeout.request`. When `null`, both timeouts default to 2_147_483_647 seconds (so not completely disabled, but close enough).

The `timeout.request_count` is the number of individual requests allowed within a single keepalive session. This protects against a client consuming the connection by sending unlimited meaningless but valid HTTP requests.

When the three are combined, it should be difficult for a problematic client to stay connected indefinitely.

If you're running httpz on Windows (or, more generally, where <code>httpz.blockingMode()</code> returns true), please <a href="#blocking-mode">read the section</a> as this mode of operation is more susceptible to DOS.

## Metrics
A few basic metrics are collected using [metrics.zig](https://github.com/karlseguin/metrics.zig), a prometheus-compatible library. These can be written to an `std.io.Writer` using `try httpz.writeMetrics(writer)`. As an example:

```zig
pub fn metrics(_: *httpz.Request, res: *httpz.Response) !void {
    const writer = res.writer();
    try httpz.writeMetrics(writer);

    // if we were also using pg.zig 
    // try pg.writeMetrics(writer);
}
```

Since httpz does not provide any authorization, care should be taken before exposing this. 

The metrics are:

* `httpz_connections` - counts each TCP connection
* `httpz_requests` - counts each request (should  be >= httpz_connections due to keepalive)
* `httpz_timeout_active` - counts each time an "active" connection is timed out. An "active" connection is one that has (a) just connected or (b) started to send bytes. The timeout is controlled by the `timeout.request` configuration.
* `httpz_timeout_keepalive` - counts each time an "keepalive" connection is timed out. A "keepalive" connection has already received at least 1 response and the server is waiting for a new request. The timeout is controlled by the `timeout.keepalive` configuration.
* `httpz_alloc_buffer_empty` - counts number of bytes allocated due to the large buffer pool being empty. This may indicate that `workers.large_buffer_count` should be larger.
* `httpz_alloc_buffer_large` - counts number of bytes allocated due to the large buffer pool being too small. This may indicate that `workers.large_buffer_size` should be larger.
* `httpz_alloc_unescape` - counts number of bytes allocated due to unescaping query or form parameters. This may indicate that `request.buffer_size` should be larger.
* `httpz_internal_error` - counts number of unexpected errors within httpz. Such errors normally result in the connection being abruptly closed. For example, a failing syscall to epoll/kqueue would increment this counter.
* `httpz_invalid_request` - counts number of requests which httpz could not parse (where the request is invalid).
* `httpz_header_too_big` - counts the number of requests which httpz rejects due to a header being too big (does not fit in `request.buffer_size` config).
* `httpz_body_too_big` - counts the number of requests which httpz rejects due to a body being too big (is larger than `request.max_body_size` config).

# Blocking Mode
kqueue (BSD, MacOS) or epoll (Linux) are used on supported platforms. On all other platforms (most notably Windows), a more naive thread-per-connection with blocking sockets is used.

The comptime-safe, `httpz.blockingMode() bool` function can be called to determine which mode httpz is running in (when it returns `true`, then you're running the simpler blocking mode).

It is possible to force blocking mode by adding the <code>force_blocking = true</code> build option in your build.zig (it is **not** possible to force non blocking mode)

```zig
var httpz_module =  b.dependency("httpz", dep_opts);
const options = b.addOptions();
options.addOption(bool, "force_blocking", true);
httpz_module.addOptions("build", options);
```

While you should always run httpz behind a reverse proxy, it's particularly important to do so in blocking mode due to the ease with which external connections can DOS the server.

In blocking mode, `config.workers.count` is hard-coded to 1. (This worker does considerably less work than the non-blocking workers). If `config.workers.count` is > 1, than those extra workers will go towards `config.thread_pool.count`. In other words:

In non-blocking mode, if `config.workers.count = 2` and `config.thread_pool.count = 4`, then you'll have 6 threads: 2 threads that read+parse requests and send replies, and 4 threads to execute application code.

In blocking more, the same config will also use 6 threads, but there will only be: 1 thread that accepts connections, and 5 threads to read+parse requests, send replies and execute application code.

The goal is for the same configuration to result in the same # of threads regardless of the mode, and to have more thread_pool threads in blocking mode since they do more work.

In blocking mode, `config.workers.large_buffer_count` defaults to the size of the thread pool.

In blocking mode, `config.workers.max_conn` and `config.workers.min_conn` are ignored. The maximum number of connections is simply the size of the thread_pool.

If you aren't using a reverse proxy, you should always set the `config.timeout.request`, `config.timeout.keepalive` and `config.timeout.request_count` settings. In blocking mode, consider using conservative values: say 5/5/5 (5 second request timeout, 5 second keepalive timeout, and 5 keepalive count). You can monitor the `httpz_timeout_active` metric to see if the request timeout is too low.

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

# HTTP Compliance
This implementation may never be fully HTTP/1.1 compliant, as it is built with the assumption that it will sit behind a reverse proxy that is tolerant of non-compliant upstreams (e.g. nginx). (One example I know of is that the server doesn't include the mandatory Date header in the response.)

# Server Side Events
Server Side Events can be enabled by calling `res.startEventStream()`. This method takes an arbitrary context and a function pointer. The provided function will be executed in a new thread, receiving the provided context and an `std.net.Stream`. Headers can be added (via `res.headers.add`) before calling `startEventStream()`. `res.body` must not be set (directly or indirectly).

Calling `startEventStream()` automatically sets the `Content-Type`, `Cache-Control` and `Connection` header.

```zig
fn handler(_: *Request, res: *Response) !void {
    try res.startEventStream(StreamContext{}, StreamContext.handle);
}

const StreamContext = struct {
    fn handle(self: StreamContext, stream: std.net.Stream) void {
        while (true) {
            // some event loop
            stream.writeAll("event: ....") catch return;
        }
    }
}
```

# Websocket
http.zig integrates with [https://github.com/karlseguin/websocket.zig](https://github.com/karlseguin/websocket.zig). When `httpz.upgradeWebsocket` is called and succeeds, the provided `Handler` is initialized and the socket is handed over to the websocket read loop within a separate thread.

When using websocket.zig standalone, your Handler's `init` function gets a 3rd parameter: a websocket.Handshake. With the http.zig integration, `init` does not get a handshake; you should validate the `*httpz.Request` before calling `upgradeWebsocket`.

```zig
const std = @import("std");
const httpz = @import("httpz");
cont websocket = httpz.websocket;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try httpz.Server().init(allocator, .{.port = 5882});
    var router = server.router();
    // a normal route
    router.get("/ws", ws);
    try server.listen(); 
}

fn ws(req: *httpz.Request, res: *httpz.Response) !void {
    if (try httpz.upgradeWebsocket(Handler, req, res, Context{}) == false) {
        // this was not a valid websocket handshake request
        // you should probably return with an error
        res.status = 400;
        res.body = "invalid websocket handshake";
        return;
    }
    // when upgradeWebsocket succeeds, you can no longer use `res` 
}

// arbitrary data you want to pass into your Handler's `init` function
const Context = struct {

}

// this is your websocket handle
// it MUST have these 3 public functions
const Handler = struct {
    ctx: Context
    conn: *websocket.Conn,
    pub fn init(conn: *websocket.Conn, ctx: Context) !Handler {
        return .{
            .ctx = ctx,
            .conn = conn,
        };
    }

    pub fn handle(self: *Handler, message: websocket.Message) !void {
        const data = message.data;
        try self.conn.write(data); // echo the message back
    }

    pub fn close(_: *Handler) void {}
}
```
