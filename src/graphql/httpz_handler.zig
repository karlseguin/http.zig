const std = @import("std");
const graphql = @import("graphql.zig");
const schema = @import("schema.zig");
const Allocator = std.mem.Allocator;

// Forward declarations for httpz types
// These will be resolved when the module is imported
const Request = @import("httpz").Request;
const Response = @import("httpz").Response;

/// GraphQL HTTP Handler for httpz
/// Handles both GET and POST requests for GraphQL queries
pub fn GraphQLHandler(comptime Context: type) type {
    return struct {
        gql: *graphql.GraphQL,
        context_fn: ?*const fn (*Request, *Response) anyerror!Context = null,
        enable_playground: bool = true,

        const Self = @This();

        pub fn init(gql: *graphql.GraphQL) Self {
            return .{
                .gql = gql,
            };
        }

        pub fn setContextFn(self: *Self, context_fn: *const fn (*Request, *Response) anyerror!Context) void {
            self.context_fn = context_fn;
        }

        pub fn setEnablePlayground(self: *Self, enable: bool) void {
            self.enable_playground = enable;
        }

        /// Main handler for GraphQL requests
        pub fn handle(self: *Self, req: *Request, res: *Response) !void {
            // Handle GraphQL Playground (GET request without query)
            if (req.method == .GET and self.enable_playground) {
                const query_params = try req.query();
                if (query_params.get("query") == null) {
                    return self.servePlayground(res);
                }
            }

            // Get context
            const context = if (self.context_fn) |ctx_fn|
                try ctx_fn(req, res)
            else
                {};

            // Parse request
            const gql_request = try self.parseRequest(req);

            // Execute GraphQL query
            var gql_response = try self.gql.execute(gql_request, context);
            defer gql_response.deinit();

            // Send response
            res.content_type = .JSON;
            res.status = 200;

            // Handle errors
            if (gql_response.errors) |errors| {
                if (errors.len > 0) {
                    res.body = try std.fmt.allocPrint(res.arena, "{{\"errors\":[{{\"message\":\"{s}\"}}]}}", .{errors[0].message});
                    return;
                }
            }
            
            // Handle successful response with data
            if (gql_response.data) |data| {
                // Convert JSON value to string
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(res.arena);
                
                const writer = buf.writer(res.arena);
                try writer.writeAll("{\"data\":");
                try writeJsonValue(data, writer);
                try writer.writeAll("}");
                
                res.body = try buf.toOwnedSlice(res.arena);
            } else {
                res.body = "{\"data\":null}";
            }
        }

        fn parseRequest(self: *Self, req: *Request) !graphql.GraphQLRequest {
            _ = self;
            
            if (req.method == .POST) {
                // Parse JSON body
                const body = req.body() orelse return error.MissingBody;
                
                const parsed = try std.json.parseFromSlice(
                    std.json.Value,
                    req.arena,
                    body,
                    .{},
                );

                const obj = parsed.value.object;
                
                const query = if (obj.get("query")) |q| q.string else return error.MissingQuery;
                const operation_name = if (obj.get("operationName")) |op| 
                    if (op == .string) op.string else null 
                else 
                    null;
                const variables = obj.get("variables");

                return graphql.GraphQLRequest{
                    .query = query,
                    .operation_name = operation_name,
                    .variables = variables,
                };
            } else if (req.method == .GET) {
                // Parse query parameters
                const query_params = try req.query();
                
                const query = query_params.get("query") orelse return error.MissingQuery;
                const operation_name = query_params.get("operationName");
                
                // Parse variables if present
                var variables: ?std.json.Value = null;
                if (query_params.get("variables")) |vars_str| {
                    const parsed = try std.json.parseFromSlice(
                        std.json.Value,
                        req.arena,
                        vars_str,
                        .{},
                    );
                    variables = parsed.value;
                }

                return graphql.GraphQLRequest{
                    .query = query,
                    .operation_name = operation_name,
                    .variables = variables,
                };
            }

            return error.InvalidMethod;
        }

        fn writeJsonValue(value: std.json.Value, writer: anytype) !void {
            switch (value) {
                .null => try writer.writeAll("null"),
                .bool => |b| try writer.writeAll(if (b) "true" else "false"),
                .integer => |i| try writer.print("{d}", .{i}),
                .float => |f| try writer.print("{d}", .{f}),
                .number_string => |s| try writer.writeAll(s),
                .string => |s| {
                    try writer.writeAll("\"");
                    try writer.writeAll(s);
                    try writer.writeAll("\"");
                },
                .array => |arr| {
                    try writer.writeAll("[");
                    for (arr.items, 0..) |item, i| {
                        if (i > 0) try writer.writeAll(",");
                        try writeJsonValue(item, writer);
                    }
                    try writer.writeAll("]");
                },
                .object => |obj| {
                    try writer.writeAll("{");
                    var it = obj.iterator();
                    var first = true;
                    while (it.next()) |entry| {
                        if (!first) try writer.writeAll(",");
                        first = false;
                        try writer.writeAll("\"");
                        try writer.writeAll(entry.key_ptr.*);
                        try writer.writeAll("\":");
                        try writeJsonValue(entry.value_ptr.*, writer);
                    }
                    try writer.writeAll("}");
                },
            }
        }

        fn servePlayground(self: *Self, res: *Response) !void {
            _ = self;
            
            res.content_type = .HTML;
            res.status = 200;
            res.body = 
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\  <meta charset="utf-8">
                \\  <title>GraphQL Playground</title>
                \\  <meta name="viewport" content="width=device-width, initial-scale=1">
                \\  <style>
                \\    body {
                \\      margin: 0;
                \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
                \\    }
                \\    #playground {
                \\      height: 100vh;
                \\      display: flex;
                \\      flex-direction: column;
                \\    }
                \\    .header {
                \\      background: #1a1a1a;
                \\      color: white;
                \\      padding: 1rem;
                \\      font-size: 1.2rem;
                \\      font-weight: bold;
                \\    }
                \\    .container {
                \\      display: flex;
                \\      flex: 1;
                \\      overflow: hidden;
                \\    }
                \\    .editor, .result {
                \\      flex: 1;
                \\      display: flex;
                \\      flex-direction: column;
                \\      padding: 1rem;
                \\    }
                \\    .editor {
                \\      border-right: 1px solid #ddd;
                \\    }
                \\    textarea {
                \\      flex: 1;
                \\      font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
                \\      font-size: 14px;
                \\      padding: 1rem;
                \\      border: 1px solid #ddd;
                \\      border-radius: 4px;
                \\      resize: none;
                \\    }
                \\    pre {
                \\      flex: 1;
                \\      margin: 0;
                \\      padding: 1rem;
                \\      background: #f5f5f5;
                \\      border: 1px solid #ddd;
                \\      border-radius: 4px;
                \\      overflow: auto;
                \\      font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
                \\      font-size: 14px;
                \\    }
                \\    button {
                \\      background: #e10098;
                \\      color: white;
                \\      border: none;
                \\      padding: 0.75rem 2rem;
                \\      font-size: 1rem;
                \\      border-radius: 4px;
                \\      cursor: pointer;
                \\      margin: 1rem 0;
                \\    }
                \\    button:hover {
                \\      background: #c5008a;
                \\    }
                \\    h3 {
                \\      margin: 0 0 0.5rem 0;
                \\    }
                \\  </style>
                \\</head>
                \\<body>
                \\  <div id="playground">
                \\    <div class="header">GraphQL Playground - httpz</div>
                \\    <div class="container">
                \\      <div class="editor">
                \\        <h3>Query</h3>
                \\        <textarea id="query" placeholder="Enter your GraphQL query here...">query {
                \\  __schema {
                \\    queryType {
                \\      name
                \\    }
                \\  }
                \\}</textarea>
                \\        <button onclick="executeQuery()">Execute Query</button>
                \\      </div>
                \\      <div class="result">
                \\        <h3>Result</h3>
                \\        <pre id="result">Execute a query to see results...</pre>
                \\      </div>
                \\    </div>
                \\  </div>
                \\  <script>
                \\    async function executeQuery() {
                \\      const query = document.getElementById('query').value;
                \\      const resultEl = document.getElementById('result');
                \\      
                \\      try {
                \\        const response = await fetch(window.location.pathname, {
                \\          method: 'POST',
                \\          headers: {
                \\            'Content-Type': 'application/json',
                \\          },
                \\          body: JSON.stringify({ query }),
                \\        });
                \\        
                \\        const data = await response.json();
                \\        resultEl.textContent = JSON.stringify(data, null, 2);
                \\      } catch (error) {
                \\        resultEl.textContent = 'Error: ' + error.message;
                \\      }
                \\    }
                \\    
                \\    // Execute on Ctrl+Enter or Cmd+Enter
                \\    document.getElementById('query').addEventListener('keydown', (e) => {
                \\      if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
                \\        executeQuery();
                \\      }
                \\    });
                \\  </script>
                \\</body>
                \\</html>
            ;
        }
    };
}

/// Convenience function to create a GraphQL route handler
pub fn graphqlRoute(
    comptime Context: type,
    handler: *GraphQLHandler(Context),
) fn (*Request, *Response) anyerror!void {
    return struct {
        fn handle(req: *Request, res: *Response) !void {
            return handler.handle(req, res);
        }
    }.handle;
}
