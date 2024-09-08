const std = @import("std");
const httpz = @import("httpz");

const websocket = httpz.websocket;

const Allocator = std.mem.Allocator;

const PORT = 8808;

// websocket.zig is verbose, let's limit it to err messages
pub const std_options = .{ .log_scope_levels = &[_]std.log.ScopeLevel{
    .{ .scope = .websocket, .level = .err },
} };

// This example show how to upgrade a request to websocket.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // For websocket support, you _must_ define a Handler, and your Handler _must_
    // have a WebsocketHandler decleration
    var server = try httpz.Server(Handler).init(allocator, .{ .port = PORT }, Handler{});

    defer server.deinit();

    // ensures a clean shutdown, finishing off any existing requests
    // see 09_shutdown.zig for how to to break server.listen with an interrupt
    defer server.stop();

    var router = server.router(.{});

    router.get("/", index, .{});

    router.get("/ws", ws, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{PORT});

    // Starts the server, this is blocking.
    try server.listen();
}

const Handler = struct {
    // or you could define the full structure here
    pub const WebsocketHandler = Client;
};

const Client = struct {
    user_id: u32,
    conn: *websocket.Conn,

    const Context = struct {
        user_id: u32,
    };

    // context is any abitrary data that you want, you'll pass it to upgradeWebsocket
    pub fn init(conn: *websocket.Conn, ctx: *const Context) !Client {
        return .{
            .conn = conn,
            .user_id = ctx.user_id,
        };
    }

    // at this point, it's safe to write to conn
    pub fn afterInit(self: *Client) !void {
        return self.conn.write("welcome!");
    }

    pub fn clientMessage(self: *Client, data: []const u8) !void {
        // echo back to client
        return self.conn.write(data);
    }
};

fn index(_: Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!DOCTYPE html>
        \\ <p>httpz integrates with my own <a href="https://github.com/karlseguin/websocket.zig/">websocket.zig</a>.
        \\ <p>A websocket connection should already be established.</p>
        \\ <p>Copy and paste the following in your browser console to have the server echo back:</p>
        \\ <pre>ws.send("hello from the client!");</pre>
        \\ <script>
        \\ const ws = new WebSocket("ws://localhost:8808/ws");
        \\ ws.addEventListener("message", (event) => { console.log("from server: ", event.data) });
        \\ </script>
    ;
}

fn ws(_: Handler, req: *httpz.Request, res: *httpz.Response) !void {
    // Could do authentication or anything else before upgrading the connection
    // The context is any arbitrary data you want to pass to Client.init.
    const ctx = Client.Context{ .user_id = 9001 };

    // The first parameter, Client, ***MUST*** be the same as Handler.WebSocketHandler
    // I'm sorry about the awkwardness of that.
    // It's undefined behavior if they don't match, and it _will_ behave weirdly/crash.
    if (try httpz.upgradeWebsocket(Client, req, res, &ctx) == false) {
        res.status = 500;
        res.body = "invalid websocket";
    }
    // unsafe to use req or res at this point!
}
