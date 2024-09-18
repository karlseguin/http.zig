# An HTTP/1.1 server for Zig.

```zig
const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  // More advance cases will use a custom "Handler" instead of "void".
  // The last parameter is our handler instance, since we have a "void"
  // handler, we passed a void ({}) value.
  var server = try httpz.Server(void).init(allocator, .{.port = 5882}, {});
  defer {
    // clean shutdown, finishes serving any live request
    server.stop();
    server.deinit();
  }
  
  var router = server.router(.{});
  router.get("/api/user/:id", getUser, .{});

  // blocks
  try server.listen(); 
}

fn getUser(req: *httpz.Request, res: *httpz.Response) !void {
  res.status = 200;
  try res.json(.{.id = req.param("id").?, .name = "Teg"}, .{});
}
```

# Table of Contents
* [Examples](#examples)
* [Installation](#installation)
* [Alternatives](#alternatives)
* [Handler](#handler)
  - [Custom Dispatch](#custom-dispatch)
  - [Per-Request Context](#per-request-context)
  - [Custom Not Found](#not-found)
  - [Custom Error Handler](#error-handler)
  - [Dispatch Takeover](#takover)
* [Memory And Arenas](#memory-and-arenas)
* [httpz.Request](httpzrequest)
* [httpz.Response](httpzresponse)
* [Router](#router)
* [Middlewares](#middlewares)
* [Configuration](#configuration)
* [Metrics](#metrics)
* [Testing](#testing)
* [HTTP Compliance](#http-compliance)
* [Server Side Events](#server-side-events)
* [Websocket](#websocket)

# Migration
If you're coming from a previous version, I've made some breaking changes recently (largely to accomodate much better integration with websocket.zig). See the [Migration Wiki](https://github.com/karlseguin/http.zig/wiki/Migration) for more details.

# Examples
See the [examples](https://github.com/karlseguin/http.zig/tree/master/examples) folder for examples. If you clone this repository, you can run `zig build example_#` to run a specific example:

```bash
$ zig build example_1
listening http://localhost:8800/
```

# Installation
1) Add http.zig as a dependency in your `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/karlseguin/http.zig#master
```

2) In your `build.zig`, add the `httpz` module as a dependency you your program:

```zig
const httpz = b.dependency("httpz", .{
    .target = target,
    .optimize = optimize,
});

// the executable from your call to b.addExecutable(...)
exe.root_module.addImport("httpz", httpz.module("httpz"));
```

The library tracks Zig master. If you're using a specific version of Zig, use the appropriate branch.

# Alternatives
If you're looking for a higher level web framework with more included functionality, consider [JetZig](https://www.jetzig.dev/) which is built on top of httpz.

## Why not std.http.Server
`std.http.Server` is very slow and assumes well-behaved clients.

There are many Zig HTTP server implementations. Most wrap `std.http.Server` and tend to be slow. Benchmark it, you'll see. A few wrap C libraries and are faster (though some of these are slow too!). 

http.zig is written in Zig, without using `std.http.Server`. On an M2, a basic request can hit 140K requests per seconds.

# Handler
When a non-void Handler is used, the value given to `Server(H).init` is passed to every action. This is how application-specific data can be passed into your actions.

For example, using [pg.zig](https://github.com/karlseguin/pg.zig), we can make a database connection pool available to each action:

```zig
const pg = @import("pg");
const std = @import("std");
const httpz = @import("httpz");

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();

  var db = try pg.Pool.init(allocator, .{
    .connect = .{ .port = 5432, .host = "localhost"},
    .auth = .{.username = "user", .database = "db", .password = "pass"}
  });
  defer db.deinit();

  var app = App{
    .db = db,
  };

  var server = try httpz.Server(*App).init(allocator, .{.port = 5882}, &app);
  var router = server.router(.{});
  router.get("/api/user/:id", getUser, .{});
  try server.listen();
}

const App = struct {
    db: *pg.Pool,
};

fn getUser(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
  const user_id = req.param("id").?;

  var row = try app.db.row("select name from users where id = $1", .{user_id}) orelse {
    res.status = 404;
    res.body = "Not found";
    return;
  };
  defer row.deinit() catch {};

  try res.json(.{
    .id = user_id,
    .name = row.get([]u8, 0),
  }, .{});
}
```

## Custom Dispatch
Beyond sharing state, your custom handler can be used to control how httpz behaves. By defining a public `dispatch` method you can control how (or even **if**) actions are executed. For example, to log timing, you could do:

```zig
const App = struct {
  pub fn dispatch(self: *App, action: httpz.Action(*App), req: *httpz.Request, res: *httpz.Response) !void {
    var timer = try std.time.Timer.start();

    // your `dispatch` doesn't _have_ to call the action
    try action(self, req, res);

    const elapsed = timer.lap() / 1000; // ns -> us
    std.log.info("{} {s} {d}", .{req.method, req.url.path, elapsed});
  }
};
```

### Per-Request Context
The 2nd parameter, `action`, is of type `httpz.Action(*App)`. This is a function pointer to the function you specified when setting up the routes. As we've seen, this works well to share global data. But, in many cases, you'll want to have request-specific data.

Consider the case where you want your `dispatch` method to conditionally load a user (maybe from the `Authorization` header of the request). How would you pass this `User` to the action? You can't use the `*App` directly, as this is shared concurrently across all requests.

To achieve this, we'll add another structure called `RequestContext`. You can call this whatever you want, and it can contain any fields of methods you want.

```zig
const RequestContext = struct {
  // You don't have to put a reference to your global data.
  // But chances are you'll want.
  app: *App,
  user: ?User,
};
```

We can now change the definition of our actions and `dispatch` method:

```zig
fn getUser(ctx: *RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
   // can check if ctx.user is != null
}

const App = struct {
  pub fn dispatch(self: *App, action: httpz.Action(*RequestContext), req: *httpz.Request, res: *httpz.Response) !void {
    var ctx = RequestContext{
      .app = self,
      .user = self.loadUser(req),
    }
    return action(&ctx, req, res);
  }

  fn loadUser(self: *App, req: *httpz.Request) ?User {
    // todo, maybe using req.header("authorizaation")
  }
};

```

httpz infers the type of the action based on the 2nd parameter of your handler's `dispatch` method. If you use a `void` handler or your handler doesn't have a `dispatch` method, then you won't interact with `httpz.Action(H)` directly.

## Not Found
If your handler has a public `notFound` method, it will be called whenever a path doesn't match a found route:

```zig
const App = struct {
  pub fn notFound(_: *App, req: *httpz.Request, res: *httpz.Response) !void {
    std.log.info("404 {} {s}", .{req.method, req.url.path});
    res.status = 404;
    res.body = "Not Found";
  }
};
```

## Error Handler
If your handler has a public `uncaughtError` method, it will be called whenever there's an unhandled error. This could be due to some internal httpz bug, or because your action return an error. 

```zig
const App = struct {
  pub fn uncaughtError(self: *App, _: *Request, res: *Response, err: anyerror) void {
    std.log.info("500 {} {s} {}", .{req.method, req.url.path, err});
    res.status = 500;
    res.body = "sorry";
  }
};
```

Notice that, unlike `notFound` and other normal actions, the `uncaughtError` method cannot return an error itself.

## Takeover
For the most control, you can define a `handle` method. This circumvents most of Httpz's dispatching, including routing. Frameworks like JetZig hook use `handle` in order to provide their own routing and dispatching. When you define a `handle` method, then any `dispatch`, `notFound` and `uncaughtError` methods are ignored by httpz.

```zig
const App = struct {
  pub fn handle(app: *App, req: *Request, res: *Response) void {
    // todo
  }
};
```

The behavior `httpz.Server(H)` is controlled by 
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

    var router = server.router(.{});

    // use get/post/put/head/patch/options/delete
    // you can also use "all" to attach to all methods
    router.get("/api/user/:id", getUser, .{});

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

Alternatively, you can explicitly call `res.write()`. Once `res.write()` returns, the response is sent and your action can cleanup/release any resources.

`res.arena` is actually a configurable-sized thread-local buffer that fallsback to an `std.heap.ArenaAllocator`. In other words, it's fast so it should be your first option for data that needs to live only until your action exits.

# httpz.Request
The following fields are the most useful:

* `method` - an httpz.Method enum
* `arena` - A fast thread-local buffer that fallsback to an ArenaAllocator, same as `res.arena`.
* `url.path` - the path of the request (`[]const u8`)
* `address` - the std.net.Address of the client

If you give your route a `data` configuration, the value can be retrieved from the optional `route_data` field of the request.

## Path Parameters
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

## Header Values
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
var it = req.headers.iterator();
while (it.next()) |kv| {
  // kv.key
  // kv.value
}
```

## QueryString
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
var it = req.query().iterator();
while (it.next()) |kv| {
  // kv.key
  // kv.value
}
```

## Body
The body of the request, if any, can be accessed using `req.body()`. This returns a `?[]const u8`.

### Json Body
The `req.json(TYPE)` function is a wrapper around the `body()` function which will call `std.json.parse` on the body. This function does not consider the content-type of the request and will try to parse any body.

```zig
if (try req.json(User)) |user| {

}
```

### JsonValueTree Body
The `req.jsonValueTree()` function is a wrapper around the `body()` function which will call `std.json.Parse` on the body, returning a `!?std.jsonValueTree`. This function does not consider the content-type of the request and will try to parse any body.

```zig
if (try req.jsonValueTree()) |t| {
    // probably want to be more defensive than this
    const product_type = r.root.Object.get("type").?.String;
    //...
}
```

### JsonObject Body
The even more specific `jsonObject()` function will return an `std.json.ObjectMap` provided the body is a map

```zig
if (try req.jsonObject()) |t| {
    // probably want to be more defensive than this
    const product_type = t.get("type").?.String;
    //...
}
```

## Form Data
The body of the request, if any, can be parsed as a "x-www-form-urlencoded "value  using `req.formData()`. The `request.max_form_count` configuration value must be set to the maximum number of form fields to support. This defaults to 0.

This behaves similarly to `query()`.

On first call, the `formData` function attempts to parse the body. This can require memory allocations to unescape encoded values. The parsed value is internally cached, so subsequent calls to `formData()` are fast and cannot fail.

The original casing of both the key and the name are preserved.

To iterate over all fields, use:

```zig
var it = (try req.formData()).iterator();
while (it.next()) |kv| {
  // kv.key
  // kv.value
}
```

Once this function is called, `req.multiFormData()` will no longer work (because the body is assumed parsed).

## Multi Part Form Data
Similar to the above, `req.multiFormData()` can be called to parse requests with a "multipart/form-data" content type. The `request.max_multiform_count` configuration value must be set to the maximum number of form fields to support. This defaults to 0.

This is a different API than `formData` because the return type is different. Rather than a simple string=>value type, the multi part form data value consists of a `value: []const u8` and a `filename: ?[]const u8`.

On first call, the `multiFormData` function attempts to parse the body. The parsed value is internally cached, so subsequent calls to `multiFormData()` are fast and cannot fail.

The original casing of both the key and the name are preserved.

To iterate over all fields, use:

```zig
var it = req.multiFormData.iterator();
while (it.next()) |kv| {
  // kv.key
  // kv.value.value
  // kv.value.filename (optional)
}
```

Once this function is called, `req.formData()` will no longer work (because the body is assumed parsed).

Advance warning: This is one of the few methods that can modify the request in-place. For most people this won't be an issue, but if you use `req.body()` and `req.multiFormData()`, say to log the raw body, the content-disposition field names are escaped in-place. It's still safe to use `req.body()` but any  content-disposition name that was escaped will be a little off.

# httpz.Response
The following fields are the most useful:

* `status` - set the status code, by default, each response starts off with a 200 status code
* `content_type` - an httpz.ContentType enum value. This is a convenience and optimization over using the `res.header` function.
* `arena` - A fast thread-local buffer that fallsback to an ArenaAllocator, same as `req.arena`.

## Body
The simplest way to set a body is to set `res.body` to a `[]const u8`. **However** the provided value must remain valid until the body is written, which happens after the function exists or when `res.write()` is explicitly called.

## Dynamic Content
You can use the `res.arena` allocator to create dynamic content:

```zig
const query = try req.query();
const name = query.get("name") orelse "stranger";
res.body = try std.fmt.allocPrint(res.arena, "Hello {s}", .{name});
```

Memory allocated with `res.arena` will exist until the response is sent.

## io.Writer
`res.writer()` returns an `std.io.Writer`. Various types support writing to an io.Writer. For example, the built-in JSON stream writer can use this writer:

```zig
var ws = std.json.writeStream(res.writer(), 4);
try ws.beginObject();
try ws.objectField("name");
try ws.emitString(req.param("name").?);
try ws.endObject();
```

## JSON
The `res.json` function will set the content_type to `httpz.ContentType.JSON` and serialize the provided value using `std.json.stringify`. The 2nd argument to the json function is the `std.json.StringifyOptions` to pass to the `stringify` function.

This function uses `res.writer()` explained above.

## Header Value
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

## Writing
By default, httpz will automatically flush your response. In more advance cases, you can use `res.write()` to explicitly flush it. This is useful in cases where you have resources that need to be freed/released only after the response is written. For example, my [LRU cache](https://github.com/karlseguin/cache.zig) uses atomic referencing counting to safely allow concurrent access to cached data. This requires callers to "release" the cached entry:

```zig
pub fn info(app: *MyApp, _: *httpz.Request, res: *httpz.Response) !void {
    const cached = app.cache.get("info") orelse {
        // load the info
    };
    defer cached.release();

    res.body = cached.value;
    return res.write();
}
```

# Router
You get an instance of the router by calling `server.route(.{})`. Currently, the configuration takes a single parameter:

* `middlewares` - A list of middlewares to apply to each request. These middleware will be executed even for requests with no matching route (i.e. not found). An individual route can opt-out of these middleware, see the `middleware_strategy` route configuration.

You can use the `get`, `put`, `post`, `head`, `patch`, `trace`, `delete` or `options` method of the router to define a router. You can also use the special `all` method to add a route for all methods.

These functions can all `@panic` as they allocate memory. Each function has an equivalent `tryXYZ` variant which will return an error rather than panicking:

```zig
// this can panic if it fails to create the route
router.get("/", index, .{});

// this returns a !void (which you can try/catch)
router.tryGet("/", index, .{});
```

The 3rd parameter is a route configuration. It allows you to speficy a different `handler` and/or `dispatch` method and/or `middleware`.

```zig
// this can panic if it fails to create the route
router.get("/", index, .{
  .dispatcher = Handler.dispathAuth,
  .handler = &auth_handler,
  .middlewares = &.{cors_middleware},
});
```

## Configuration
The last parameter to the various `router` methods is a route configuration. In many cases, you'll probably use an empty configuration (`.{}`). The route configuration has three fields:

* `dispatcher` - The dispatch method to use. This overrides the default dispatcher, which is either httpz built-in dispatcher or [your handler's `dispatch` method](#custom-dispatch).
* `handler` - The handler instance to use. The default handler is the 3rd parameter passed to `Server(H).init` but you can override this on a route-per-route basis.
* `middlewares` - A list of [middlewares](#middlewares) to run. By default, no middlewares are run. By default, this list of middleware is appended to the list given to `server.route(.{.middlewares = .{....})`.
* `middleware_strategy` - How the given middleware should be merged with the global middlewares. Defaults to `.append`, can also be `.replace`.
* `data` - Arbitrary data (`*const anyopaque`) to make available to `req.route_data`. This must be a `const`.

You can specify a separate configuration for each route. To change the configuration for a group of routes, you have two options. The first, is to directly change the router's `handler`, `dispatcher` and `middlewares` field. Any subsequent routes will use these values:

```zig
var server = try httpz.Server(Handler).init(allocator, .{.port = 5882}, &handler);
  
var router = server.router(.{});

// Will use Handler.dispatch on the &handler instance passed to init
// No middleware
router.get("/route1", route1, .{});

router.dispatcher = Handler.dispathAuth;
// uses the new dispatcher
router.get("/route2", route2, .{}); 

router.handler = &Handler{.public = true};
// uses the new dispatcher + new handler
router.get("/route3", route3, .{.handler = Handler.dispathAuth});
```

This approach is error prone though. New routes need to be carefully added in the correct order so that the desired handler, dispatcher and middlewares are used.

A more scalable option is to use route groups.

## Groups
Defining a custom dispatcher or custom global data on each route can be tedious. Instead, consider using a router group:

```zig
var admin_routes = router.group("/admin", .{
  .handler = &auth_handler,
  .dispatcher = Handler.dispathAuth,
  .middlewares = &.{cors_middleware},
});
admin_routes.get("/users", listUsers, .{});
admin_routs.delete("/users/:id", deleteUsers, .{});
```

The first parameter to `group` is a prefix to prepend to each route in the group. An empty prefix is acceptable. Thus, route groups can be used to configure either a common prefix and/or a common configuration across multiple routes.

## Casing
You **must** use a lowercase route. You can use any casing with parameter names, as long as you use that same casing when getting the parameter.

## Parameters
Routing supports parameters, via `:CAPTURE_NAME`. The captured values are available via `req.params.get(name: []const u8) ?[]const u8`.  

## Glob
You can glob an individual path segment, or the entire path suffix. For a suffix glob, it is important that no trailing slash is present.

```zig
// prefer using a custom `notFound` handler than a global glob.
router.all("/*", not_found, .{});
router.get("/api/*/debug", .{})
```

When multiple globs are used, the most specific will be selected. E.g., give the following two routes:

```zig
router.get("/*", not_found, .{});
router.get("/info/*", any_info, .{})
```

A request for "/info/debug/all" will be routed to `any_info`, whereas a request for "/over/9000" will be routed to `not_found`.

## Limitations
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

# Middlewares
In general, use a [custom dispatch](#custom-dispatch) function to apply custom logic, such as logging, authentication and authorization. If you have complex route-specific logic, middleware can also be leveraged.

A middleware is a struct which exposes a nested `Config` type, a public `init` function and a public `execute` method. It can optionally define a `deinit` method. See the built-in [CORS middleware](https://github.com/karlseguin/http.zig/blob/master/src/middleware/Cors.zig) or the sample [logger middleware](https://github.com/karlseguin/http.zig/blob/master/example/middleware/Logger.zig) for examples.

A middleware instance is created using `server.middleware()` and can then be used with the router:

```zig
var server = try httpz.Server(void).init(allocator, .{.port = 5882}, {});

// the middleware method takes the struct name and its configuration
const cors = try server.middleware(httpz.middleware.Cors, .{
  .origin = "https://www.openmymind.net/",
});

// apply this middleware to all routes (unless the route 
// explicitly opts out)
var router = server.router(.{.middlewares = .{cors}});

// or we could add middleware on a route-per-route bassis
router.get("/v1/users", .{.middlewares = &.{cors}});

// by default, middlewares on a route are appended to the global middlewares
// we can replace them instead by specifying a middleware_strategy
router.get("/v1/metrics", .{.middlewares = &.{cors}, .middleware_strategy = .replace});
```

## Cors
httpz comes with a built-in CORS middleware: `httpz.middlewares.Cors`. Its configuration is:

* `origin: []const u8`
* `headers: ?[]const u8 = null`
* `methods: ?[]const u8 = null`
* `max_age: ?[]const u8 = null`

The CORS middleware will include a `Access-Control-Allow-Origin: $origin` to every request. For an OPTIONS request where the `sec-fetch-mode` is set to `cors, the `Access-Control-Allow-Headers`, `Access-Control-Allow-Methods` and `Access-Control-Max-Age` response headers will optionally be set based on the configuration.


# Configuration
The second parameter given to `Server(H).init` is an `httpz.Config`. When running in <a href=#blocking-mode>blocking mode</a> (e.g. on Windows) a few of these behave slightly, but not drastically, different.

There are many configuration options. 

`thread_pool.buffer_size` is the single most important value to tweak. Usage of `req.arena`, `res.arena`, `res.writer()` and `res.json()` all use a fallback allocator which first uses a fast thread-local buffer and then an underlying arena. The total memory this will require is `thread_pool.count * thread_pool.buffer_size`. Since `thread_pool.count` is usually small, a large `buffer_size` is reasonable.

`request.buffer_size` must be large enough to fit the request header. Any extra space might be used to read the body. However, there can be up to `workers.count * workers.max_conn` pending requests, so a large `request.buffer_size` can take up a lot of memory. Instead, consider keeping `request.buffer_size` only large enough for the header (plus a bit of overhead for decoding URL-escape values) and set `workers.large_buffer_size` to a reasonable size for your incoming request bodies. This will take `workers.count * workers.large_buffer_count * workers.large_buffer_size` memory. 

Buffers for request bodies larger than `workers.large_buffer_size` but smaller than `request.max_body_size` will be dynamic allocated.

In addition to a bit of overhead, at a minimum, httpz will use:

```zig
(thread_pool.count * thread_pool.buffer_size) +
(workers.count * workers.large_buffer_count * workers.large_buffer_size) +
(workers.count * workers.min_conn * request.buffer_size)
```

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
        .max_conn = 8_192,

        // Minimum number of connection states each worker should maintain
        // (blocking mode: currently ignored)
        .min_conn = 64,

        // A pool of larger buffers that can be used for any data larger than configured
        // static buffers. For example, if response headers don't fit in in 
        // $response.header_buffer_size, a buffer will be pulled from here.
        // This is per-worker. 
        .large_buffer_count = 16,

        // The size of each large buffer.
        .large_buffer_size = 65536,

        // Size of bytes retained for the connection arena between use. This will
        // result in up to `count * min_conn * retain_allocated_bytes` of memory usage.
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

    // options for tweaking request processing
    .request = .{
        // Maximum body size that we'll process. We can allocate up 
        // to this much memory per request for the body. Internally, we might
        // keep this memory around for a number of requests as an optimization.
        .max_body_size: usize = 1_048_576,

        // This memory is allocated upfront. The request header _must_ fit into
        // this space, else the request will be rejected.
        .buffer_size: usize = 4_096,

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
        max_message_size: ?usize = null,
        small_buffer_size: ?usize = null,
        small_buffer_pool: ?usize = null,
        large_buffer_size: ?usize = null,
        large_buffer_pool: ?u16 = null,
    },
});
```

## Blocking Mode
kqueue (BSD, MacOS) or epoll (Linux) are used on supported platforms. On all other platforms (most notably Windows), a more naive thread-per-connection with blocking sockets is used.

The comptime-safe, `httpz.blockingMode() bool` function can be called to determine which mode httpz is running in (when it returns `true`, then you're running the simpler blocking mode).

While you should always run httpz behind a reverse proxy, it's particularly important to do so in blocking mode due to the ease with which external connections can DOS the server.

In blocking mode, `config.workers.count` is hard-coded to 1. (This worker does considerably less work than the non-blocking workers). If `config.workers.count` is > 1, than those extra workers will go towards `config.thread_pool.count`. In other words:

In non-blocking mode, if `config.workers.count = 2` and `config.thread_pool.count = 4`, then you'll have 6 threads: 2 threads that read+parse requests and send replies, and 4 threads to execute application code.

In blocking mode, the same config will also use 6 threads, but there will only be: 1 thread that accepts connections, and 5 threads to read+parse requests, send replies and execute application code.

The goal is for the same configuration to result in the same # of threads regardless of the mode, and to have more thread_pool threads in blocking mode since they do more work.

In blocking mode, `config.workers.large_buffer_count` defaults to the size of the thread pool.

In blocking mode, `config.workers.max_conn` and `config.workers.min_conn` are ignored. The maximum number of connections is simply the size of the thread_pool.

If you aren't using a reverse proxy, you should always set the `config.timeout.request`, `config.timeout.keepalive` and `config.timeout.request_count` settings. In blocking mode, consider using conservative values: say 5/5/5 (5 second request timeout, 5 second keepalive timeout, and 5 keepalive count). You can monitor the `httpz_timeout_active` metric to see if the request timeout is too low.

## Timeouts
The configuration settings under the `timeouts` section are designed to help protect the system against basic DOS attacks (say, by connecting and not sending data). However it is recommended that you leave these null (disabled) and use the appropriate timeout in your reverse proxy (e.g. NGINX). 

The `timeout.request` is the time, in seconds, that a connection has to send a complete request. The `timeout.keepalive` is the time, in second, that a connection can stay connected without sending a request (after the initial request has been sent).

The connection alternates between these two timeouts. It starts with a timeout of `timeout.request` and after the response is sent and the connection is placed in the "keepalive list", switches to the `timeout.keepalive`. When new data is received, it switches back to `timeout.request`. When `null`, both timeouts default to 2_147_483_647 seconds (so not completely disabled, but close enough).

The `timeout.request_count` is the number of individual requests allowed within a single keepalive session. This protects against a client consuming the connection by sending unlimited meaningless but valid HTTP requests.

When the three are combined, it should be difficult for a problematic client to stay connected indefinitely.

If you're running httpz on Windows (or, more generally, where <code>httpz.blockingMode()</code> returns true), please <a href="#blocking-mode">read the section</a> as this mode of operation is more susceptible to DOS.

# Metrics
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

# Testing
The `httpz.testing` namespace exists to help application developers setup an `*httpz.Request` and assert an `*httpz.Response`.

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
// OR 
// This requires ht.init(.{.request = .{.max_form_count = 10}})
web_test.form(.{.over = "9000"});

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
http.zig integrates with [https://github.com/karlseguin/websocket.zig](https://github.com/karlseguin/websocket.zig) by calling `httpz.upgradeWebsocket()`. First, your handler must have a `WebsocketHandler` declaration which is the WebSocket handler type used by `websocket.Server(H)`.

```zig
const websocket = httpz.websocket;

const Handler = struct {
  // App-specific data you want to pass when initializing
  // your WebSocketHandler
  const WebsocketContext = struct {

  };

  // See the websocket.zig documentation. But essentially this is your
  // Application's wrapper around 1 websocket connection
  pub const WebsocketHandler = struct {
    conn: *websocket.Conn,

    // ctx is arbitrary data you passs to httpz.upgradeWebsocket
    pub fn init(conn: *websocket.Conn, _: WebsocketContext) {
      return .{
        .conn =  conn,
      }
    }

    // echo back
    pub fn clientMessage(self: *WebsocketHandler, data: []const u8) !void {
        try self.conn.write(data);
    }
  }  
};
```

With this in place, you can call httpz.upgradeWebsocket() within an action:

```zig
fn ws(req: *httpz.Request, res: *httpz.Response) !void {
  if (try httpz.upgradeWebsocket(WebsocketHandler, req, res, WebsocketContext{}) == false) {
  // this was not a valid websocket handshake request
  // you should probably return with an error
  res.status = 400;
  res.body = "invalid websocket handshake";
  return;
  }
  // Do not use `res` from this point on
}
```

In websocket.zig, `init` is passed a `websocket.Handshake`. This is not the case with the httpz integration - you are expected to do any necessary validation of the request in the action.

It is an undefined behavior if `Handler.WebsocketHandler` is not the same type passed to `httpz.upgradeWebsocket`.
