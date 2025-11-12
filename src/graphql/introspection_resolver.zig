const std = @import("std");
const types = @import("types.zig");
const schema = @import("schema.zig");
const Allocator = std.mem.Allocator;

/// Context for schema introspection resolver
pub const SchemaContext = struct {
    schema_ptr: *schema.Schema,
    allocator: Allocator,
};

/// Create a resolver that returns schema introspection data
pub fn createSchemaResolver(allocator: Allocator, gql_schema: *schema.Schema) !types.ResolverFn {
    const ctx = try allocator.create(SchemaContext);
    ctx.* = .{
        .schema_ptr = gql_schema,
        .allocator = allocator,
    };
    
    const Wrapper = struct {
        fn resolve(ctx_ptr: *anyopaque) anyerror!types.Value {
            const context: *SchemaContext = @ptrCast(@alignCast(ctx_ptr));
            const alloc = context.allocator;
            
            // Build schema introspection response
            var result = std.StringHashMap(types.Value).init(alloc);
            
            // Add queryType
            if (context.schema_ptr.query_type) |qt| {
                var query_type_map = std.StringHashMap(types.Value).init(alloc);
                try query_type_map.put("name", types.Value{ .string = qt.name });
                try query_type_map.put("kind", types.Value{ .string = "OBJECT" });
                try result.put("queryType", types.Value{ .object = query_type_map });
            }
            
            // Add mutationType (null for now)
            try result.put("mutationType", types.Value.null_value);
            
            // Add subscriptionType (null for now)
            try result.put("subscriptionType", types.Value.null_value);
            
            // Add types array
            var types_list: std.ArrayList(types.Value) = .empty;
            
            // Add Query type
            if (context.schema_ptr.query_type) |qt| {
                const type_obj = try buildTypeObject(alloc, qt);
                try types_list.append(alloc, types.Value{ .object = type_obj });
            }
            
            // Add custom types
            var type_it = context.schema_ptr.types.iterator();
            while (type_it.next()) |entry| {
                const type_obj = try buildTypeObject(alloc, entry.value_ptr.*);
                try types_list.append(alloc, types.Value{ .object = type_obj });
            }
            
            // Add scalar types
            const scalar_names = [_][]const u8{ "String", "Int", "Float", "Boolean", "ID" };
            for (scalar_names) |scalar_name| {
                var scalar_obj = std.StringHashMap(types.Value).init(alloc);
                try scalar_obj.put("name", types.Value{ .string = scalar_name });
                try scalar_obj.put("kind", types.Value{ .string = "SCALAR" });
                try scalar_obj.put("description", types.Value.null_value);
                try scalar_obj.put("fields", types.Value.null_value);
                try scalar_obj.put("interfaces", types.Value.null_value);
                try scalar_obj.put("possibleTypes", types.Value.null_value);
                try scalar_obj.put("enumValues", types.Value.null_value);
                try scalar_obj.put("inputFields", types.Value.null_value);
                try types_list.append(alloc, types.Value{ .object = scalar_obj });
            }
            
            try result.put("types", types.Value{ .list = try types_list.toOwnedSlice(alloc) });
            
            // Add directives (empty for now)
            var directives_list: std.ArrayList(types.Value) = .empty;
            try result.put("directives", types.Value{ .list = try directives_list.toOwnedSlice(alloc) });
            
            return types.Value{ .object = result };
        }
    };
    return Wrapper.resolve;
}

fn buildTypeObject(allocator: Allocator, object_type: *types.ObjectType) !std.StringHashMap(types.Value) {
    var type_map = std.StringHashMap(types.Value).init(allocator);
    
    try type_map.put("name", types.Value{ .string = object_type.name });
    try type_map.put("kind", types.Value{ .string = "OBJECT" });
    try type_map.put("description", if (object_type.description) |desc|
        types.Value{ .string = desc }
    else
        types.Value.null_value);
    
    // Add fields
    var fields_list: std.ArrayList(types.Value) = .empty;
    var field_it = object_type.fields.iterator();
    while (field_it.next()) |entry| {
        var field_map = std.StringHashMap(types.Value).init(allocator);
        try field_map.put("name", types.Value{ .string = entry.value_ptr.name });
        try field_map.put("description", if (entry.value_ptr.description) |desc|
            types.Value{ .string = desc }
        else
            types.Value.null_value);
        
        // Add type info
        var type_ref = std.StringHashMap(types.Value).init(allocator);
        try type_ref.put("name", types.Value{ .string = entry.value_ptr.type_name });
        try type_ref.put("kind", types.Value{ .string = "SCALAR" }); // Simplified
        try field_map.put("type", types.Value{ .object = type_ref });
        
        // Add args (empty for now)
        var args_list: std.ArrayList(types.Value) = .empty;
        try field_map.put("args", types.Value{ .list = try args_list.toOwnedSlice(allocator) });
        
        try field_map.put("isDeprecated", types.Value{ .boolean = false });
        try field_map.put("deprecationReason", types.Value.null_value);
        
        try fields_list.append(allocator, types.Value{ .object = field_map });
    }
    try type_map.put("fields", types.Value{ .list = try fields_list.toOwnedSlice(allocator) });
    
    // Add other required fields
    try type_map.put("interfaces", types.Value.null_value);
    try type_map.put("possibleTypes", types.Value.null_value);
    try type_map.put("enumValues", types.Value.null_value);
    try type_map.put("inputFields", types.Value.null_value);
    
    return type_map;
}
