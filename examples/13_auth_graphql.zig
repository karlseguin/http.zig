const std = @import("std");
const httpz = @import("httpz");
const graphql = @import("graphql");
const Allocator = std.mem.Allocator;

const PORT = 8813;

// User data structure
const User = struct {
    id: []const u8,
    email: []const u8,
    username: []const u8,
    password: []const u8, // In real app, this would be hashed
    created_at: i64,
    
    pub fn clone(self: User, allocator: Allocator) !User {
        return User{
            .id = try allocator.dupe(u8, self.id),
            .email = try allocator.dupe(u8, self.email),
            .username = try allocator.dupe(u8, self.username),
            .password = try allocator.dupe(u8, self.password),
            .created_at = self.created_at,
        };
    }
};

// Auth response
const AuthResponse = struct {
    success: bool,
    message: []const u8,
    token: ?[]const u8,
    user: ?User,
};

// Mock user storage
var users_storage: std.StringHashMap(User) = undefined;
var storage_mutex: std.Thread.Mutex = .{};
var next_user_id: usize = 1;

// Global handler
var global_handler: ?*graphql.GraphQLHandler(void) = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize user storage
    users_storage = std.StringHashMap(User).init(allocator);
    defer {
        var it = users_storage.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        users_storage.deinit();
    }

    // Add some mock users
    try addMockUser(allocator, "john@example.com", "john_doe", "password123");
    try addMockUser(allocator, "jane@example.com", "jane_smith", "secret456");

    // Create GraphQL schema
    var gql_schema = try createAuthSchema(allocator);
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

    std.debug.print("🔐 Auth GraphQL server listening on http://localhost:{d}/graphql\n", .{PORT});
    std.debug.print("📝 Open http://localhost:{d}/graphql in your browser for the playground\n", .{PORT});
    std.debug.print("\n📚 Example queries:\n", .{});
    std.debug.print("  Signup: mutation {{ signup(email: \"user@example.com\", username: \"newuser\", password: \"pass123\") {{ success message token }} }}\n", .{});
    std.debug.print("  Signin: mutation {{ signin(email: \"john@example.com\", password: \"password123\") {{ success message token }} }}\n", .{});
    std.debug.print("  Users:  query {{ users {{ id email username }} }}\n\n", .{});

    try server.listen();
}

fn handleGraphQL(req: *httpz.Request, res: *httpz.Response) !void {
    if (global_handler) |handler| {
        return handler.handle(req, res);
    }
    res.status = 500;
    res.body = "GraphQL handler not initialized";
}

fn addMockUser(allocator: Allocator, email: []const u8, username: []const u8, password: []const u8) !void {
    storage_mutex.lock();
    defer storage_mutex.unlock();

    const id = try std.fmt.allocPrint(allocator, "{d}", .{next_user_id});
    next_user_id += 1;

    const user = User{
        .id = id,
        .email = try allocator.dupe(u8, email),
        .username = try allocator.dupe(u8, username),
        .password = try allocator.dupe(u8, password),
        .created_at = std.time.timestamp(),
    };

    const key = try allocator.dupe(u8, email);
    try users_storage.put(key, user);
}

fn createUsersResolver(allocator: Allocator) graphql.types.ResolverFn {
    _ = allocator;
    const Wrapper = struct {
        fn resolve(ctx: *anyopaque) anyerror!graphql.types.Value {
            _ = ctx;
            storage_mutex.lock();
            defer storage_mutex.unlock();
            
            const count = users_storage.count();
            return graphql.types.Value{ .string = if (count == 0) "No users" else if (count == 1) "1 user registered" else "Multiple users registered" };
        }
    };
    return Wrapper.resolve;
}

fn createSignupResolver(allocator: Allocator) graphql.types.ResolverFn {
    _ = allocator;
    const Wrapper = struct {
        fn resolve(ctx: *anyopaque) anyerror!graphql.types.Value {
            _ = ctx;
            // For now, return success message
            return graphql.types.Value{ .string = "Signup successful! Token: mock-jwt-token-new-user" };
        }
    };
    return Wrapper.resolve;
}

fn createSigninResolver(allocator: Allocator) graphql.types.ResolverFn {
    _ = allocator;
    const Wrapper = struct {
        fn resolve(ctx: *anyopaque) anyerror!graphql.types.Value {
            _ = ctx;
            // For now, return success message
            return graphql.types.Value{ .string = "Signin successful! Token: mock-jwt-token-authenticated" };
        }
    };
    return Wrapper.resolve;
}

fn createAuthSchema(allocator: Allocator) !graphql.schema.Schema {
    var gql_schema = try graphql.schema.Schema.init(allocator);

    // Create User type
    const user_type = try allocator.create(graphql.types.ObjectType);
    user_type.* = try graphql.types.ObjectType.init(allocator, "User");
    user_type.description = try allocator.dupe(u8, "A registered user");

    const id_field = try graphql.types.Field.init(allocator, "id", "ID!");
    try user_type.addField(id_field);

    const email_field = try graphql.types.Field.init(allocator, "email", "String!");
    try user_type.addField(email_field);

    const username_field = try graphql.types.Field.init(allocator, "username", "String!");
    try user_type.addField(username_field);

    const created_at_field = try graphql.types.Field.init(allocator, "createdAt", "Int!");
    try user_type.addField(created_at_field);

    try gql_schema.addType(user_type);

    // Create AuthResponse type
    const auth_response_type = try allocator.create(graphql.types.ObjectType);
    auth_response_type.* = try graphql.types.ObjectType.init(allocator, "AuthResponse");
    auth_response_type.description = try allocator.dupe(u8, "Authentication response");

    const success_field = try graphql.types.Field.init(allocator, "success", "Boolean!");
    try auth_response_type.addField(success_field);

    const message_field = try graphql.types.Field.init(allocator, "message", "String!");
    try auth_response_type.addField(message_field);

    const token_field = try graphql.types.Field.init(allocator, "token", "String");
    try auth_response_type.addField(token_field);

    try gql_schema.addType(auth_response_type);

    // Create Query type
    const query_type = try allocator.create(graphql.types.ObjectType);
    query_type.* = try graphql.types.ObjectType.init(allocator, "Query");

    var users_field = try graphql.types.Field.init(allocator, "users", "String!");
    users_field.description = try allocator.dupe(u8, "Get all registered users (count)");
    users_field.resolver = createUsersResolver(allocator);
    try query_type.addField(users_field);

    var me_field = try graphql.types.Field.init(allocator, "me", "User");
    me_field.description = try allocator.dupe(u8, "Get current authenticated user");
    me_field.resolver = graphql.resolver.nullResolver();
    try query_type.addField(me_field);

    gql_schema.setQueryType(query_type);

    // Create Mutation type
    const mutation_type = try allocator.create(graphql.types.ObjectType);
    mutation_type.* = try graphql.types.ObjectType.init(allocator, "Mutation");

    // Signup mutation
    var signup_field = try graphql.types.Field.init(allocator, "signup", "String!");
    signup_field.description = try allocator.dupe(u8, "Register a new user");
    
    const signup_email_arg = graphql.types.Argument{
        .name = try allocator.dupe(u8, "email"),
        .type_name = try allocator.dupe(u8, "String!"),
        .allocator = allocator,
    };
    try signup_field.addArgument(signup_email_arg);
    
    const signup_username_arg = graphql.types.Argument{
        .name = try allocator.dupe(u8, "username"),
        .type_name = try allocator.dupe(u8, "String!"),
        .allocator = allocator,
    };
    try signup_field.addArgument(signup_username_arg);
    
    const signup_password_arg = graphql.types.Argument{
        .name = try allocator.dupe(u8, "password"),
        .type_name = try allocator.dupe(u8, "String!"),
        .allocator = allocator,
    };
    try signup_field.addArgument(signup_password_arg);
    
    signup_field.resolver = createSignupResolver(allocator);
    try mutation_type.addField(signup_field);

    // Signin mutation
    var signin_field = try graphql.types.Field.init(allocator, "signin", "String!");
    signin_field.description = try allocator.dupe(u8, "Sign in with email and password");
    
    const signin_email_arg = graphql.types.Argument{
        .name = try allocator.dupe(u8, "email"),
        .type_name = try allocator.dupe(u8, "String!"),
        .allocator = allocator,
    };
    try signin_field.addArgument(signin_email_arg);
    
    const signin_password_arg = graphql.types.Argument{
        .name = try allocator.dupe(u8, "password"),
        .type_name = try allocator.dupe(u8, "String!"),
        .allocator = allocator,
    };
    try signin_field.addArgument(signin_password_arg);
    
    signin_field.resolver = createSigninResolver(allocator);
    try mutation_type.addField(signin_field);

    gql_schema.setMutationType(mutation_type);

    // Add introspection
    var typename_field = try graphql.types.Field.init(allocator, "__typename", "String!");
    typename_field.description = try allocator.dupe(u8, "The name of the current Object type at runtime");
    typename_field.resolver = graphql.resolver.stringResolver("Query");
    try query_type.addField(typename_field);

    try gql_schema.validate();

    return gql_schema;
}
