const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const schema = @import("schema.zig");

/// GraphQL Introspection System
/// Implements the __schema and __type introspection fields

pub fn addIntrospectionFields(gql_schema: *schema.Schema) !void {
    if (gql_schema.query_type) |query_type| {
        // Add __schema field
        var schema_field = try types.Field.init(
            gql_schema.allocator,
            "__schema",
            "__Schema!",
        );
        schema_field.description = try gql_schema.allocator.dupe(
            u8,
            "Access the current type schema of this server.",
        );
        try query_type.addField(schema_field);

        // Add __type field
        var type_field = try types.Field.init(
            gql_schema.allocator,
            "__type",
            "__Type",
        );
        type_field.description = try gql_schema.allocator.dupe(
            u8,
            "Request the type information of a single type.",
        );
        
        const name_arg = types.Argument{
            .name = try gql_schema.allocator.dupe(u8, "name"),
            .type_name = try gql_schema.allocator.dupe(u8, "String!"),
            .allocator = gql_schema.allocator,
        };
        try type_field.addArgument(name_arg);
        
        try query_type.addField(type_field);
    }
}

pub fn createIntrospectionTypes(allocator: Allocator) !std.ArrayList(*types.ObjectType) {
    var introspection_types: std.ArrayList(*types.ObjectType) = .empty;

    // __Schema type
    const schema_type = try allocator.create(types.ObjectType);
    schema_type.* = try types.ObjectType.init(allocator, "__Schema");
    schema_type.description = try allocator.dupe(
        u8,
        "A GraphQL Schema defines the capabilities of a GraphQL server.",
    );
    
    var types_field = try types.Field.init(allocator, "types", "[__Type!]!");
    types_field.description = try allocator.dupe(u8, "A list of all types supported by this server.");
    try schema_type.addField(types_field);
    
    var query_type_field = try types.Field.init(allocator, "queryType", "__Type!");
    query_type_field.description = try allocator.dupe(u8, "The type that query operations will be rooted at.");
    try schema_type.addField(query_type_field);
    
    var mutation_type_field = try types.Field.init(allocator, "mutationType", "__Type");
    mutation_type_field.description = try allocator.dupe(u8, "If this server supports mutation, the type that mutation operations will be rooted at.");
    try schema_type.addField(mutation_type_field);
    
    try introspection_types.append(allocator, schema_type);

    // __Type type
    const type_type = try allocator.create(types.ObjectType);
    type_type.* = try types.ObjectType.init(allocator, "__Type");
    type_type.description = try allocator.dupe(
        u8,
        "The fundamental unit of any GraphQL Schema is the type.",
    );
    
    const kind_field = try types.Field.init(allocator, "kind", "__TypeKind!");
    try type_type.addField(kind_field);
    
    const name_field = try types.Field.init(allocator, "name", "String");
    try type_type.addField(name_field);
    
    const description_field = try types.Field.init(allocator, "description", "String");
    try type_type.addField(description_field);
    
    var fields_field = try types.Field.init(allocator, "fields", "[__Field!]");
    const include_deprecated_arg = types.Argument{
        .name = try allocator.dupe(u8, "includeDeprecated"),
        .type_name = try allocator.dupe(u8, "Boolean"),
        .default_value = types.Value{ .boolean = false },
        .allocator = allocator,
    };
    try fields_field.addArgument(include_deprecated_arg);
    try type_type.addField(fields_field);
    
    try introspection_types.append(allocator, type_type);

    // __Field type
    const field_type = try allocator.create(types.ObjectType);
    field_type.* = try types.ObjectType.init(allocator, "__Field");
    
    const field_name_field = try types.Field.init(allocator, "name", "String!");
    try field_type.addField(field_name_field);
    
    const field_description_field = try types.Field.init(allocator, "description", "String");
    try field_type.addField(field_description_field);
    
    const field_args_field = try types.Field.init(allocator, "args", "[__InputValue!]!");
    try field_type.addField(field_args_field);
    
    const field_type_field = try types.Field.init(allocator, "type", "__Type!");
    try field_type.addField(field_type_field);
    
    try introspection_types.append(allocator, field_type);

    // __InputValue type
    const input_value_type = try allocator.create(types.ObjectType);
    input_value_type.* = try types.ObjectType.init(allocator, "__InputValue");
    
    const input_name_field = try types.Field.init(allocator, "name", "String!");
    try input_value_type.addField(input_name_field);
    
    const input_description_field = try types.Field.init(allocator, "description", "String");
    try input_value_type.addField(input_description_field);
    
    const input_type_field = try types.Field.init(allocator, "type", "__Type!");
    try input_value_type.addField(input_type_field);
    
    const input_default_value_field = try types.Field.init(allocator, "defaultValue", "String");
    try input_value_type.addField(input_default_value_field);
    
    try introspection_types.append(allocator, input_value_type);

    return introspection_types;
}

pub fn createIntrospectionEnums(allocator: Allocator) !std.ArrayList(*types.EnumType) {
    var introspection_enums: std.ArrayList(*types.EnumType) = .empty;

    // __TypeKind enum
    const type_kind_enum = try allocator.create(types.EnumType);
    type_kind_enum.* = try types.EnumType.init(allocator, "__TypeKind");
    type_kind_enum.description = try allocator.dupe(
        u8,
        "An enum describing what kind of type a given __Type is.",
    );
    
    const kind_values = [_][]const u8{
        "SCALAR",
        "OBJECT",
        "INTERFACE",
        "UNION",
        "ENUM",
        "INPUT_OBJECT",
        "LIST",
        "NON_NULL",
    };
    
    for (kind_values) |kind_value| {
        const enum_value = types.EnumValue{
            .name = try allocator.dupe(u8, kind_value),
            .value = try allocator.dupe(u8, kind_value),
            .allocator = allocator,
        };
        try type_kind_enum.addValue(enum_value);
    }
    
    try introspection_enums.append(allocator, type_kind_enum);

    // __DirectiveLocation enum
    const directive_location_enum = try allocator.create(types.EnumType);
    directive_location_enum.* = try types.EnumType.init(allocator, "__DirectiveLocation");
    directive_location_enum.description = try allocator.dupe(
        u8,
        "A Directive can be adjacent to many parts of the GraphQL language.",
    );
    
    const location_values = [_][]const u8{
        "QUERY",
        "MUTATION",
        "SUBSCRIPTION",
        "FIELD",
        "FRAGMENT_DEFINITION",
        "FRAGMENT_SPREAD",
        "INLINE_FRAGMENT",
        "SCHEMA",
        "SCALAR",
        "OBJECT",
        "FIELD_DEFINITION",
        "ARGUMENT_DEFINITION",
        "INTERFACE",
        "UNION",
        "ENUM",
        "ENUM_VALUE",
        "INPUT_OBJECT",
        "INPUT_FIELD_DEFINITION",
    };
    
    for (location_values) |location_value| {
        const enum_value = types.EnumValue{
            .name = try allocator.dupe(u8, location_value),
            .value = try allocator.dupe(u8, location_value),
            .allocator = allocator,
        };
        try directive_location_enum.addValue(enum_value);
    }
    
    try introspection_enums.append(allocator, directive_location_enum);

    return introspection_enums;
}

test "Create introspection types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var introspection_types = try createIntrospectionTypes(allocator);
    defer {
        for (introspection_types.items) |t| {
            t.deinit();
            allocator.destroy(t);
        }
        introspection_types.deinit();
    }

    try testing.expect(introspection_types.items.len > 0);
}

test "Create introspection enums" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var introspection_enums = try createIntrospectionEnums(allocator);
    defer {
        for (introspection_enums.items) |e| {
            e.deinit();
            allocator.destroy(e);
        }
        introspection_enums.deinit();
    }

    try testing.expect(introspection_enums.items.len > 0);
}
