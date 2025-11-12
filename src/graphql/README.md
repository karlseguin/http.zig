# GraphQL Module for httpz

A complete, production-ready GraphQL implementation in Zig.

## Module Structure

```
graphql/
├── graphql.zig          # Main module entry point
├── types.zig            # GraphQL type system (scalars, objects, enums)
├── schema.zig           # Schema definition and validation
├── parser.zig           # GraphQL query parser
├── executor.zig         # Query execution engine
├── introspection.zig    # Schema introspection support
└── httpz_handler.zig    # HTTP integration with httpz
```

## Quick Example

```zig
const graphql = @import("graphql");

// Create schema
var schema = try graphql.Schema.init(allocator);
defer schema.deinit();

// Define types
const query_type = try allocator.create(graphql.ObjectType);
query_type.* = try graphql.ObjectType.init(allocator, "Query");

var hello_field = try graphql.Field.init(allocator, "hello", "String!");
hello_field.resolver = resolveHello;
try query_type.addField(hello_field);

schema.setQueryType(query_type);

// Execute queries
var gql = graphql.GraphQL.init(allocator, &schema);
const result = try gql.execute(.{ .query = "{ hello }" }, {});
```

## Features

- ✅ Complete GraphQL query parser
- ✅ Type-safe schema builder
- ✅ Field resolvers with custom context
- ✅ Introspection support
- ✅ Built-in GraphQL Playground
- ✅ httpz HTTP handler integration
- ✅ Memory-safe with proper cleanup

## Documentation

See [GRAPHQL.md](../../GRAPHQL.md) for complete documentation.

## Testing

Run tests:
```bash
zig build test
```

## Example

Run the GraphQL example server:
```bash
zig build example_12
./zig-out/bin/example_12
```

Then visit `http://localhost:8812/graphql` for the playground.
