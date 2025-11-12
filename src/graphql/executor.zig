const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const schema = @import("schema.zig");
const parser = @import("parser.zig");
const graphql = @import("graphql.zig");

pub fn execute(
    allocator: Allocator,
    gql_schema: *schema.Schema,
    document: *parser.Document,
    variables: ?std.json.Value,
    context: anytype,
) !graphql.GraphQLResponse {
    _ = variables; // TODO: Implement variable support
    
    if (document.operations.items.len == 0) {
        const errors = try allocator.alloc(graphql.GraphQLErrorInfo, 1);
        errors[0] = .{ .message = try allocator.dupe(u8, "No operations found in document") };
        return graphql.GraphQLResponse{
            .allocator = allocator,
            .errors = errors,
        };
    }

    // Execute the first operation (TODO: support operation name selection)
    const operation = &document.operations.items[0];
    
    const root_type = switch (operation.operation_type) {
        .Query => gql_schema.query_type,
        .Mutation => gql_schema.mutation_type,
        .Subscription => gql_schema.subscription_type,
    };

    if (root_type == null) {
        const errors = try allocator.alloc(graphql.GraphQLErrorInfo, 1);
        errors[0] = .{
            .message = try std.fmt.allocPrint(
                allocator,
                "Schema does not support {s} operations",
                .{@tagName(operation.operation_type)},
            ),
        };
        return graphql.GraphQLResponse{
            .allocator = allocator,
            .errors = errors,
        };
    }

    // Execute selections
    var result_map = std.json.ObjectMap.init(allocator);
    
    for (operation.selections.items) |*selection| {
        const field_result = try executeSelection(
            allocator,
            gql_schema,
            root_type.?,
            selection,
            null,
            context,
        );
        
        const field_name = selection.alias orelse selection.name;
        try result_map.put(
            try allocator.dupe(u8, field_name),
            field_result,
        );
    }

    return graphql.GraphQLResponse{
        .allocator = allocator,
        .data = .{ .object = result_map },
    };
}

fn executeSelection(
    allocator: Allocator,
    gql_schema: *schema.Schema,
    parent_type: *types.ObjectType,
    selection: *parser.Selection,
    parent_value: ?types.Value,
    context: anytype,
) !std.json.Value {
    _ = parent_value;
    
    const field = parent_type.getField(selection.name) orelse {
        return error.FieldNotFound;
    };

    // Execute field resolver
    const field_value = if (field.resolver) |resolver| blk: {
        var dummy_ctx: u8 = 0;
        const ctx_ptr = if (field.resolver_ctx) |ctx| ctx else @as(*anyopaque, @ptrCast(&dummy_ctx));
        const result = try resolver(ctx_ptr);
        break :blk result;
    } else blk: {
        // Default resolver - return null
        break :blk types.Value.null_value;
    };

    // If field has nested selections, resolve them
    if (selection.selections.items.len > 0) {
        const field_type_name = stripTypeModifiers(field.type_name);
        const field_type = gql_schema.getType(field_type_name) orelse {
            return error.TypeMismatch;
        };

        var nested_map = std.json.ObjectMap.init(allocator);
        
        for (selection.selections.items) |*nested_selection| {
            const nested_result = try executeSelection(
                allocator,
                gql_schema,
                field_type,
                nested_selection,
                field_value,
                context,
            );
            
            const nested_field_name = nested_selection.alias orelse nested_selection.name;
            try nested_map.put(
                try allocator.dupe(u8, nested_field_name),
                nested_result,
            );
        }
        
        return .{ .object = nested_map };
    }

    // Convert field value to JSON
    return try field_value.toJsonValue(allocator);
}

fn stripTypeModifiers(type_name: []const u8) []const u8 {
    var result = type_name;
    
    // Strip NonNull (!)
    if (result.len > 0 and result[result.len - 1] == '!') {
        result = result[0 .. result.len - 1];
    }
    
    // Strip List ([])
    if (result.len > 2 and result[0] == '[' and result[result.len - 1] == ']') {
        result = result[1 .. result.len - 1];
    }
    
    // Strip NonNull again (for [Type]!)
    if (result.len > 0 and result[result.len - 1] == '!') {
        result = result[0 .. result.len - 1];
    }
    
    return result;
}

test "Execute simple query" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create schema
    var gql_schema = try schema.Schema.init(allocator);
    defer gql_schema.deinit();

    const query_type = try allocator.create(types.ObjectType);
    query_type.* = try types.ObjectType.init(allocator, "Query");
    
    const field = try types.Field.init(allocator, "hello", "String");
    try query_type.addField(field);
    
    gql_schema.setQueryType(query_type);

    // Parse query
    const query = "{ hello }";
    var document = try parser.parse(allocator, query);
    defer document.deinit();

    // Execute (will fail without resolver, but tests the structure)
    const result = execute(allocator, &gql_schema, &document, null, {}) catch |err| {
        try testing.expect(err == error.FieldNotFound or err == error.OutOfMemory);
        return;
    };
    
    var response = result;
    defer response.deinit();
}
