const std = @import("std");
const httpz = @import("httpz");
const graphql = @import("graphql");
const Allocator = std.mem.Allocator;

const PORT = 8812;

// Global handler (will be initialized in main)
var global_handler: ?*graphql.GraphQLHandler(void) = null;

// Example data structures
const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    age: i32,
};

const Post = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    author_id: []const u8,
};

// Application context
const AppContext = struct {
    users: []const User,
    posts: []const Post,
    allocator: Allocator,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Sample data
    const users = [_]User{
        .{ .id = "1", .name = "Alice", .email = "alice@example.com", .age = 30 },
        .{ .id = "2", .name = "Bob", .email = "bob@example.com", .age = 25 },
        .{ .id = "3", .name = "Charlie", .email = "charlie@example.com", .age = 35 },
    };

    const posts = [_]Post{
        .{ .id = "1", .title = "Hello GraphQL", .content = "This is my first post", .author_id = "1" },
        .{ .id = "2", .title = "Zig is awesome", .content = "Learning Zig with httpz", .author_id = "1" },
        .{ .id = "3", .title = "GraphQL in Zig", .content = "Building GraphQL servers", .author_id = "2" },
    };

    const app_context = AppContext{
        .users = &users,
        .posts = &posts,
        .allocator = allocator,
    };

    // Create GraphQL schema
    var gql_schema = try createSchema(allocator, app_context);
    defer gql_schema.deinit();

    // Create GraphQL instance
    var gql = graphql.GraphQL.init(allocator, &gql_schema);
    defer gql.deinit();

    // Create HTTP server
    var server = try httpz.Server(void).init(allocator, .{
        .port = PORT,
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});

    // Create and store GraphQL handler
    var gql_handler = graphql.GraphQLHandler(void).init(&gql);
    gql_handler.setEnablePlayground(true);
    global_handler = &gql_handler;

    // Register GraphQL endpoint  
    router.post("/graphql", handleGraphQL, .{});
    router.get("/graphql", handleGraphQL, .{});

    std.debug.print("GraphQL server listening on http://localhost:{d}/graphql\n", .{PORT});
    std.debug.print("Open http://localhost:{d}/graphql in your browser for the playground\n", .{PORT});

    try server.listen();
}

fn handleGraphQL(req: *httpz.Request, res: *httpz.Response) !void {
    if (global_handler) |handler| {
        return handler.handle(req, res);
    }
    res.status = 500;
    res.body = "GraphQL handler not initialized";
}

fn createSchema(allocator: Allocator, ctx: AppContext) !graphql.schema.Schema {
    _ = ctx;
    
    var gql_schema = try graphql.schema.Schema.init(allocator);

    // Create User type
    const user_type = try allocator.create(graphql.types.ObjectType);
    user_type.* = try graphql.types.ObjectType.init(allocator, "User");
    user_type.description = try allocator.dupe(u8, "A user in the system");

    const id_field = try graphql.types.Field.init(allocator, "id", "ID!");
    try user_type.addField(id_field);

    const name_field = try graphql.types.Field.init(allocator, "name", "String!");
    try user_type.addField(name_field);

    const email_field = try graphql.types.Field.init(allocator, "email", "String!");
    try user_type.addField(email_field);

    const age_field = try graphql.types.Field.init(allocator, "age", "Int!");
    try user_type.addField(age_field);

    try gql_schema.addType(user_type);

    // Create Post type
    const post_type = try allocator.create(graphql.types.ObjectType);
    post_type.* = try graphql.types.ObjectType.init(allocator, "Post");
    post_type.description = try allocator.dupe(u8, "A blog post");

    const post_id_field = try graphql.types.Field.init(allocator, "id", "ID!");
    try post_type.addField(post_id_field);

    const title_field = try graphql.types.Field.init(allocator, "title", "String!");
    try post_type.addField(title_field);

    const content_field = try graphql.types.Field.init(allocator, "content", "String!");
    try post_type.addField(content_field);

    try gql_schema.addType(post_type);

    // Create Query type
    const query_type = try allocator.create(graphql.types.ObjectType);
    query_type.* = try graphql.types.ObjectType.init(allocator, "Query");

    var users_field = try graphql.types.Field.init(allocator, "users", "[User!]!");
    users_field.description = try allocator.dupe(u8, "Get all users");
    try query_type.addField(users_field);

    var user_field = try graphql.types.Field.init(allocator, "user", "User");
    user_field.description = try allocator.dupe(u8, "Get a user by ID");
    const id_arg = graphql.types.Argument{
        .name = try allocator.dupe(u8, "id"),
        .type_name = try allocator.dupe(u8, "ID!"),
        .allocator = allocator,
    };
    try user_field.addArgument(id_arg);
    try query_type.addField(user_field);

    var posts_field = try graphql.types.Field.init(allocator, "posts", "[Post!]!");
    posts_field.description = try allocator.dupe(u8, "Get all posts");
    try query_type.addField(posts_field);

    var hello_field = try graphql.types.Field.init(allocator, "hello", "String!");
    hello_field.description = try allocator.dupe(u8, "A simple hello world");
    hello_field.resolver = graphql.resolver.stringResolver("Hello from GraphQL in Zig!");
    try query_type.addField(hello_field);
    
    var version_field = try graphql.types.Field.init(allocator, "version", "String!");
    version_field.description = try allocator.dupe(u8, "API version");
    version_field.resolver = graphql.resolver.stringResolver("1.0.0");
    try query_type.addField(version_field);
    
    var count_field = try graphql.types.Field.init(allocator, "count", "Int!");
    count_field.description = try allocator.dupe(u8, "Sample count");
    count_field.resolver = graphql.resolver.intResolver(42);
    try query_type.addField(count_field);
    
    gql_schema.setQueryType(query_type);
    
    // Add simple introspection - just __typename for now
    // Full __schema introspection has memory issues that need more work
    var typename_field = try graphql.types.Field.init(allocator, "__typename", "String!");
    typename_field.description = try allocator.dupe(u8, "The name of the current Object type at runtime");
    typename_field.resolver = graphql.resolver.stringResolver("Query");
    try query_type.addField(typename_field);

    try gql_schema.validate();

    return gql_schema;
}

// Resolvers
fn resolveHello(_: anytype, _: std.StringHashMap(graphql.types.Value), _: anytype) !graphql.types.Value {
    return graphql.types.Value{ .string = "Hello, GraphQL!" };
}

fn resolveUsers(_: anytype, _: std.StringHashMap(graphql.types.Value), ctx: AppContext) !graphql.types.Value {
    var list = std.ArrayList(graphql.types.Value).init(ctx.allocator);
    
    for (ctx.users) |_| {
        // Return placeholder - in real implementation, would convert User to Value
        try list.append(graphql.types.Value.null_value);
    }
    
    return graphql.types.Value{ .list = try list.toOwnedSlice() };
}

fn resolveUser(_: anytype, args: std.StringHashMap(graphql.types.Value), ctx: AppContext) !graphql.types.Value {
    const id_value = args.get("id") orelse return graphql.types.Value.null_value;
    
    if (id_value != .string) return graphql.types.Value.null_value;
    
    for (ctx.users) |user| {
        if (std.mem.eql(u8, user.id, id_value.string)) {
            // Found user - return placeholder
            return graphql.types.Value.null_value;
        }
    }
    
    return graphql.types.Value.null_value;
}

fn resolvePosts(_: anytype, _: std.StringHashMap(graphql.types.Value), ctx: AppContext) !graphql.types.Value {
    var list = std.ArrayList(graphql.types.Value).init(ctx.allocator);
    
    for (ctx.posts) |_| {
        try list.append(graphql.types.Value.null_value);
    }
    
    return graphql.types.Value{ .list = try list.toOwnedSlice() };
}

fn resolveUserId(_: anytype, _: std.StringHashMap(graphql.types.Value), _: anytype) !graphql.types.Value {
    return graphql.types.Value{ .string = "1" };
}

fn resolveUserName(_: anytype, _: std.StringHashMap(graphql.types.Value), _: anytype) !graphql.types.Value {
    return graphql.types.Value{ .string = "Sample User" };
}

fn resolveUserEmail(_: anytype, _: std.StringHashMap(graphql.types.Value), _: anytype) !graphql.types.Value {
    return graphql.types.Value{ .string = "user@example.com" };
}

fn resolveUserAge(_: anytype, _: std.StringHashMap(graphql.types.Value), _: anytype) !graphql.types.Value {
    return graphql.types.Value{ .int = 25 };
}

fn resolvePostId(_: anytype, _: std.StringHashMap(graphql.types.Value), _: anytype) !graphql.types.Value {
    return graphql.types.Value{ .string = "1" };
}

fn resolvePostTitle(_: anytype, _: std.StringHashMap(graphql.types.Value), _: anytype) !graphql.types.Value {
    return graphql.types.Value{ .string = "Sample Post" };
}

fn resolvePostContent(_: anytype, _: std.StringHashMap(graphql.types.Value), _: anytype) !graphql.types.Value {
    return graphql.types.Value{ .string = "This is a sample post content" };
}
