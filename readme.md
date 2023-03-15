An HTTP/1.1 server for Zig.

# Installation
This library supports native Zig module (introduced in 0.11). Add a "httpz" dependency to your `build.zig.zon`.

# Usage
```zig
const httpz = @import("httpz");

fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var router = try httpz.Router.init(allocator);

    // routes MUST be lowercase (params can use any casing).
    try router.get("/api/users", get_users);
    try router.put("/api/users/:id", update_user);

    try httpz.listen(allocator, &router, .{.port = 3000});
}

fn get_users(req: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.text("todo");
}

fn update_users(req: *httpz.Request, res: *httpz.Response) !void {
    _ = req.params.get("id");
    res.status = 200;
    res.text("todo");
}
```

# Router
You can use the `get`, `put`, `post`, `head`, `patch`, `delete` or `option` method of the router to define a router. You can also use the special `all` method to add a route for all methods.

## Casing
You **must** use a lowercase route. You can use any casing with parameter names, as long as you use that same casing when requested the parameter.

## Parameters
Routing supports parameters, via `:CAPTURE_NAME`. The captured values are available via `req.params.get(name: []const u8) ?[]const u8`.  

## Glob
You can glob an individual path segment, or the entire path suffix. For a suffix glob, it is important that no trailing slash is present.

```
res.all("/*", not_found);
res.get("/api/*/debug")
```

When multiple globs are used, the most specific will be selected. E.g., give the following two routes:

```
res.get("/*", not_found);
res.get("/info/*", any_info)
```

A request for "/info/debug/all" will be routed to `any_info`, whereas a request for "/over/9000" will be routed to `not_found`.

## Limitations
The router has several limitations which might not get fixed. These specifically resolve around the interaction of globs, parameters and static path segments.

Given the following routes:

```
try router.get("/:any/users", route1);
try router.get("/hello/users/test", route2);
```

You would expect a request to "/hello/users" to be routed to `route1`. However, no route will be found. 

Globs interact similarly poorly with parameters and static path segments.

Resolving this issue requires keeping a stack (or visiting the routes recursively), in order to back-out of a dead-end and trying a different path.
This seems like an unnecessarily expensive thing to do, on each request, when, in my opinion, such route hierarchies are quite uncommon. 

# Zig compatibility
0.11-dev is constantly changing, but the goal is to keep this library compatible with the latest development release. Since 0.11-dev does not support async, threads are currently and there are some thread-unsafe code paths. Since this library is itself a WIP, the entire thing is considered good enough for playing/testing, and should be stable when 0.11 itself becomes more stable.

# HTTP Compliance
This implementation may never be fully HTTP/1.1 compliant, as it is built with the assumption that it will sit behind a reverse proxy that is tolerant of non-compliant upstreams (e.g. nginx). 

Things that are missing:

- 
