# GraphQL for httpz

A complete GraphQL implementation in Zig, designed to work seamlessly with the httpz HTTP server library.

## Features

- ✅ **Full GraphQL Specification Support**
  - Query, Mutation, and Subscription operations
  - Object types, Scalar types, Enums, Input types
  - Field arguments and default values
  - Type modifiers (NonNull, List)
  
- ✅ **GraphQL Parser**
  - Complete query parsing
  - Support for aliases, arguments, and nested selections
  - Variable support (in progress)
  - Fragment support (planned)

- ✅ **Schema Definition**
  - Type-safe schema builder
  - Field resolvers with custom logic
  - Schema validation
  - Introspection support

- ✅ **httpz Integration**
  - Built-in HTTP handler for GraphQL endpoints
  - GraphQL Playground UI
  - Support for both GET and POST requests
  - JSON request/response handling

- ✅ **Developer Experience**
  - Beautiful GraphQL Playground interface
  - Comprehensive error messages
  - Type-safe resolver functions
  - Memory-safe with proper cleanup

## Quick Start

### 1. Basic GraphQL Server

```zig
const std = @import("std");
const httpz = @import("httpz");
const graphql = @import("graphql");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Create schema
    var schema = try graphql.Schema.init(allocator);
    defer schema.deinit();

    // Define Query type
    const query_type = try allocator.create(graphql.ObjectType);
    query_type.* = try graphql.ObjectType.init(allocator, "Query");
    
    var hello_field = try graphql.Field.init(allocator, "hello", "String!");
    hello_field.resolver = resolveHello;
    try query_type.addField(hello_field);
    
    schema.setQueryType(query_type);
    try schema.validate();

    // Create GraphQL instance
    var gql = graphql.GraphQL.init(allocator, &schema);
    defer gql.deinit();

    // Create HTTP server
    var server = try httpz.Server(void).init(allocator, .{ .port = 8080 }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});

    // Create GraphQL handler
    var gql_handler = graphql.GraphQLHandler(void).init(&gql);
    
    // Register GraphQL endpoint
    router.post("/graphql", graphqlHandler, .{ .handler = &gql_handler });
    router.get("/graphql", graphqlHandler, .{ .handler = &gql_handler });

    std.debug.print("GraphQL server at http://localhost:8080/graphql\n", .{});
    try server.listen();
}

fn graphqlHandler(
    handler: *graphql.GraphQLHandler(void),
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    return handler.handle(req, res);
}

fn resolveHello(_: anytype, _: std.StringHashMap(graphql.Value), _: anytype) !graphql.Value {
    return graphql.Value{ .string = "Hello, GraphQL!" };
}
```

### 2. Schema with Multiple Types

```zig
// Define User type
const user_type = try allocator.create(graphql.ObjectType);
user_type.* = try graphql.ObjectType.init(allocator, "User");

var id_field = try graphql.Field.init(allocator, "id", "ID!");
id_field.resolver = resolveUserId;
try user_type.addField(id_field);

var name_field = try graphql.Field.init(allocator, "name", "String!");
name_field.resolver = resolveUserName;
try user_type.addField(name_field);

try schema.addType(user_type);

// Define Query type with user field
const query_type = try allocator.create(graphql.ObjectType);
query_type.* = try graphql.ObjectType.init(allocator, "Query");

var user_field = try graphql.Field.init(allocator, "user", "User");
user_field.resolver = resolveUser;

// Add argument to user field
const id_arg = graphql.Argument{
    .name = try allocator.dupe(u8, "id"),
    .type_name = try allocator.dupe(u8, "ID!"),
    .allocator = allocator,
};
try user_field.addArgument(id_arg);

try query_type.addField(user_field);
schema.setQueryType(query_type);
```

### 3. Resolvers with Context

```zig
const AppContext = struct {
    database: *Database,
    current_user: ?User,
};

fn resolveUser(
    _: anytype,
    args: std.StringHashMap(graphql.Value),
    ctx: AppContext,
) !graphql.Value {
    const id = args.get("id") orelse return graphql.Value.null_value;
    
    // Query database
    const user = try ctx.database.findUser(id.string);
    
    // Convert to GraphQL value
    var obj = std.StringHashMap(graphql.Value).init(ctx.allocator);
    try obj.put("id", graphql.Value{ .string = user.id });
    try obj.put("name", graphql.Value{ .string = user.name });
    
    return graphql.Value{ .object = obj };
}
```

### 4. Enums

```zig
const role_enum = try allocator.create(graphql.EnumType);
role_enum.* = try graphql.EnumType.init(allocator, "Role");

const admin_value = graphql.EnumValue{
    .name = try allocator.dupe(u8, "ADMIN"),
    .value = try allocator.dupe(u8, "admin"),
    .allocator = allocator,
};
try role_enum.addValue(admin_value);

const user_value = graphql.EnumValue{
    .name = try allocator.dupe(u8, "USER"),
    .value = try allocator.dupe(u8, "user"),
    .allocator = allocator,
};
try role_enum.addValue(user_value);

try schema.addEnum(role_enum);
```

### 5. Mutations

```zig
const mutation_type = try allocator.create(graphql.ObjectType);
mutation_type.* = try graphql.ObjectType.init(allocator, "Mutation");

var create_user_field = try graphql.Field.init(allocator, "createUser", "User!");
create_user_field.resolver = resolveCreateUser;

const name_arg = graphql.Argument{
    .name = try allocator.dupe(u8, "name"),
    .type_name = try allocator.dupe(u8, "String!"),
    .allocator = allocator,
};
try create_user_field.addArgument(name_arg);

try mutation_type.addField(create_user_field);
schema.setMutationType(mutation_type);
```

## GraphQL Playground

The built-in GraphQL Playground provides an interactive interface for testing queries:

1. Navigate to your GraphQL endpoint in a browser (e.g., `http://localhost:8080/graphql`)
2. The playground will load automatically for GET requests without a query parameter
3. Write your query in the left panel
4. Click "Execute Query" or press Ctrl+Enter (Cmd+Enter on Mac)
5. View results in the right panel

### Example Queries

```graphql
# Simple query
query {
  hello
}

# Query with arguments
query {
  user(id: "123") {
    id
    name
    email
  }
}

# Multiple fields
query {
  users {
    id
    name
  }
  posts {
    title
    content
  }
}

# Aliases
query {
  admin: user(id: "1") {
    name
  }
  regularUser: user(id: "2") {
    name
  }
}

# Introspection
query {
  __schema {
    queryType {
      name
    }
    types {
      name
      kind
    }
  }
}
```

## API Reference

### Core Types

#### `GraphQL`
Main GraphQL execution engine.

```zig
pub const GraphQL = struct {
    pub fn init(allocator: Allocator, schema: *Schema) GraphQL
    pub fn execute(self: *GraphQL, request: GraphQLRequest, context: anytype) !GraphQLResponse
    pub fn deinit(self: *GraphQL) void
}
```

#### `Schema`
GraphQL schema definition.

```zig
pub const Schema = struct {
    pub fn init(allocator: Allocator) !Schema
    pub fn setQueryType(self: *Schema, query_type: *ObjectType) void
    pub fn setMutationType(self: *Schema, mutation_type: *ObjectType) void
    pub fn addType(self: *Schema, object_type: *ObjectType) !void
    pub fn addEnum(self: *Schema, enum_type: *EnumType) !void
    pub fn validate(self: *const Schema) !void
    pub fn deinit(self: *Schema) void
}
```

#### `ObjectType`
GraphQL object type with fields.

```zig
pub const ObjectType = struct {
    pub fn init(allocator: Allocator, name: []const u8) !ObjectType
    pub fn addField(self: *ObjectType, field: Field) !void
    pub fn getField(self: *const ObjectType, name: []const u8) ?*Field
    pub fn deinit(self: *ObjectType) void
}
```

#### `Field`
GraphQL field with resolver.

```zig
pub const Field = struct {
    name: []const u8,
    type_name: []const u8,
    resolver: ?*const fn (parent: anytype, args: StringHashMap(Value), ctx: anytype) anyerror!Value,
    
    pub fn init(allocator: Allocator, name: []const u8, type_name: []const u8) !Field
    pub fn addArgument(self: *Field, arg: Argument) !void
    pub fn deinit(self: *Field) void
}
```

#### `Value`
GraphQL value type.

```zig
pub const Value = union(enum) {
    null_value,
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    list: []Value,
    object: StringHashMap(Value),
}
```

### HTTP Handler

#### `GraphQLHandler`
HTTP handler for GraphQL requests.

```zig
pub fn GraphQLHandler(comptime Context: type) type {
    return struct {
        pub fn init(gql: *GraphQL) Self
        pub fn setEnablePlayground(self: *Self, enable: bool) void
        pub fn handle(self: *Self, req: *httpz.Request, res: *httpz.Response) !void
    }
}
```

## Building and Running

### Build the GraphQL Example

```bash
zig build example_12
```

### Run the Example

```bash
./zig-out/bin/example_12
```

Then open `http://localhost:8812/graphql` in your browser.

### Run Tests

```bash
zig build test
```

## Architecture

The GraphQL implementation consists of several layers:

1. **Parser Layer** (`parser.zig`)
   - Lexical analysis and tokenization
   - AST construction
   - Query validation

2. **Type System** (`types.zig`)
   - Scalar types (Int, Float, String, Boolean, ID)
   - Object types with fields
   - Enums and Input types
   - Type modifiers (NonNull, List)

3. **Schema Layer** (`schema.zig`)
   - Schema definition and validation
   - Type registration
   - Schema introspection

4. **Execution Layer** (`executor.zig`)
   - Query execution
   - Field resolution
   - Error handling

5. **HTTP Integration** (`httpz_handler.zig`)
   - Request parsing (GET/POST)
   - Response formatting
   - Playground UI

## Performance Considerations

- **Memory Management**: All allocations use the provided allocator with proper cleanup
- **Zero-Copy**: String operations avoid unnecessary copies where possible
- **Efficient Parsing**: Single-pass parser with minimal backtracking
- **Resolver Caching**: Field resolvers are stored as function pointers

## Roadmap

- [x] Basic query execution
- [x] Object types and fields
- [x] Arguments and resolvers
- [x] Enums
- [x] HTTP integration
- [x] GraphQL Playground
- [ ] Variables support
- [ ] Fragments
- [ ] Directives (@skip, @include)
- [ ] Subscriptions (WebSocket)
- [ ] Query complexity analysis
- [ ] DataLoader pattern
- [ ] Schema SDL parsing
- [ ] Federation support

## Contributing

Contributions are welcome! Please ensure:

1. All tests pass: `zig build test`
2. Code follows Zig style guidelines
3. New features include tests
4. Documentation is updated

## License

Same as httpz library.

## Examples

See `examples/12_graphql.zig` for a complete working example with:
- Multiple types (User, Post)
- Queries with arguments
- Nested field resolution
- Context usage
- GraphQL Playground

## Support

For issues, questions, or contributions, please visit the httpz repository.
