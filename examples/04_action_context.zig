const std = @import("std");
const httpz = @import("httpz");
const Allocator = std.mem.Allocator;

const PORT = 8804;

// This example is very similar to 03_dispatch.zig, but shows how the action
// state can be a different type than the handler.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var handler = Handler{};
    var server = try httpz.Server(*Handler).init(allocator, .{ .port = PORT }, &handler);

    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = server.router(.{});

    const restricted_route = &RouteData{ .restricted = true };

    // We can register arbitrary data to a route, which we can retrieve
    // via req.route_data. This is stored as a `*const anyopaque`.
    router.get("/", index, .{});
    router.get("/admin", admin, .{ .data = restricted_route });

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

const Handler = struct {
    // In example_3, our action type was: httpz.Action(*Handler).
    // In this example, we've changed it to:  httpz.Action(*Env)
    // This allows our handler to be a general app-wide "state" while our actions
    // received a request-specific context
    pub fn dispatch(self: *Handler, action: httpz.Action(*Env), req: *httpz.Request, res: *httpz.Response) !void {
        const user = (try req.query()).get("auth");

        // RouteData can be anything, but since it's stored as a *const anyopaque
        // you'll need to restore the type/alignment.

        // (You could also use a per-route handler, or middleware, to achieve
        // the same thing. Using route data is a bit ugly due to the type erasure
        // but it can be convenient!).
        if (req.route_data) |rd| {
            const route_data: *const RouteData = @ptrCast(@alignCast(rd));
            if (route_data.restricted and (user == null or user.?.len == 0)) {
                res.status = 401;
                res.body = "permission denied";
                return;
            }
        }

        var env = Env{
            .user = user, // todo: this is not very good security!
            .handler = self,
        };

        try action(&env, req, res);
    }
};

const RouteData = struct {
    restricted: bool,
};

const Env = struct {
    handler: *Handler,
    user: ?[]const u8,
};

fn index(_: *Env, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\ <p>The <code>Handler.dispatch</code> method takes an <code>httpz.Action(*Env)</code>.
        \\ <p>This allows the handler method to create a request-specific value to pass into actions.
        \\ <p>For example, dispatch might load a User (using a request header value maybe) and make it available to the action.
        \\ <p>Goto <a href="/admin?auth=superuser">admin</a> to simulate a (very insecure) authentication.
    ;
}

// because of our dispatch method, this can only be called when env.user != null
fn admin(env: *Env, _: *httpz.Request, res: *httpz.Response) !void {
    res.body = try std.fmt.allocPrint(res.arena, "Welcome to the admin portal, {s}", .{env.user.?});
}
