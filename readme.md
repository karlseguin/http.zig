An HTTP/1.1 server for Zig.

# Installation
This library supports native Zig module (introduced in 0.11). Add a "httpz" dependency to your `build.zig.zon`.

# Usage

## Simple Use Case
The library supports both simple and complex use cases. A simple user case is shown below. It's initiated by the call to `httpz.Server()`:

```zig
const httpz = @import("httpz");

fn main() !void {
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
const Global = struct {
    hits: usize = 0,
    l: std.Thread.Mutex = .{},
};

fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global = Global{};
    var server = try httpz.ServerCtx(*Global, *Global).init(allocator, .{}, &global);
    var router = server.router();
    router.get("/increment", increment);
    return server.listen();
}
```

There are a few important things to notice. First, the `init` function of `ServerCtx(G, R)` takes a 3rd parameter: the global data. Second, our actions take a new parameter of type `G`. Any custom notFound handler (set via `server.notFound(...)`) or error handler(set via `server.errorHandler(errorHandler)`) must also accept this new parameter. 

Because the new parameter is first, the above can also be written as:

```zig
const Global = struct {
    hits: usize = 0,
    l: std.Thread.Mutex = .{},

    fn increment(global: *Global, _: *httpz.Request, res: *httpz.Response) !void {
        global.l.lock();
        var hits = global.hits + 1;
        global.hits = hits;
        global.l.unlock();

        res.content_type = httpz.ContentType.TEXT;
        var out = try std.fmt.allocPrint(res.arena, "{d} hits", .{hits});
        res.body = out;
    }
};

fn main() !void {
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

The dispatcher can also be set directly on the router and will be used for any subsequent route. This is convenient, but error prone, as the routes must be defined in the correct order:

```zig
var router = server.router();

router.dispatcher(requiredUserDispatcher);
router.delete("/v1/session", session.delete);
router.post("/v1/password_reset", password_reset.create);

router.dispatcher(internalDispatcher);
router.get("/debug/ping", debug.ping);
router.get("/debug/metrics", debug.metrics);
```

In the above, th `requiredUserDispatcher` is used for all subsequent routes until another dispatcher is set. In other words, `requiredUserDispatcher` will be used for `/v1/session` and `/v1/password_reset` while `internalDispatcher` will be used for `/debug/ping` and `/debug/metrics`.

## Complex Use Case 3 - Per-Request Data
We can combine what we've learned from the above two uses cases and use `ServerCtx(G, R)` where `G != R`. In this case, a dispatcher **must** be provided (failure to provide a dispatcher will result in 500 errors). This is because the dispatcher is needed to generate `R`.

```zig
const Global = struct {
    hits: usize = 0,
    l: std.Thread.Mutex = .{},
};

const Context = struct {
    global: *Global,
    user_id: ?[]const u8,
}

fn main() !void {
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

## Router
You can use the `get`, `put`, `post`, `head`, `patch`, `delete` or `option` method of the router to define a router. You can also use the special `all` method to add a route for all methods.

These functions can all `@panic` as they allocate memory. Each function has an equivalent `tryXYZ` variant which will return an error rather than panicking:

```zig
// this can panic if it fails to create the route
router.get("/", index);

// this returns a !void (which you can try/catch)
router.tryGet("/", index);
```

There is also a `getC` and `tryGetC` (and `putC` and `tryPutC`, and ...) that takes a 3rd parameter: the route configuration. Most of the time, this isn't needed. So, to streamline usage and given Zig's lack of overloading or default parameters, these awkward `xyzC` functions were created. Currently, the only route configuration value is to set a custom dispatcher for the specific route.
 See [Custom Dispatcher][#complex-use-case-2---custom-dispatcher] for more information.

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

### Custom Dispatcher
While httpz doesn't support a traditional middleware stack, it does allow a custom dispatcher to be used on a per-route basis. A dispatcher is merely the function that calls the action. The default one is essentially:

```zig
fn dispatcher(action: httpz.Action(void), req: *httpz.Request, res: *httpz.Response) !void {
    return action(req, res);
}
```

A custom dispatcher does not need to invoke `action`. 

The `action` type is `httpz.Action(void)` when `httpz.Server()` is used. However, if custom [Server Contexts](#server-context) are used, via `httpz.ServerCtx(T)`, then the action type will be: `httpz.Action(T)` and the dispatch will receive a 4th parameter of type T:

```zig
fn dispatcher(action: httpz.Action(*Context), req: *httpz.Request, res: *httpz.Response, ctx: *Context) !void {
    return action(req, res, ctx);
}
```

## Configuration
The third option given to `listen` is an `httpz.Config` instance. Possible values, along with their default, are:

```zig
try httpz.listen(allocator, &router, .{
    // the port to listen on
    .port = 5882, 

    // the interface address to bind to
    .address = "127.0.0.1",

    // Minimum number of request & response objects to keep pooled
    .pool_size: usize = 100,

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

We have can test the above error case like so:

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
0.11-dev is constantly changing, but the goal is to keep this library compatible with the latest development release. Since 0.11-dev does not support async, threads are currently and there are some thread-unsafe code paths. Since this library is itself a WIP, the entire thing is considered good enough for playing/testing, and should be stable when 0.11 itself becomes more stable.

# HTTP Compliance
This implementation may never be fully HTTP/1.1 compliant, as it is built with the assumption that it will sit behind a reverse proxy that is tolerant of non-compliant upstreams (e.g. nginx). 

# websocket.zig
I'm also working on a websocket server implementation for zig: [https://github.com/karlseguin/websocket.zig](https://github.com/karlseguin/websocket.zig).
