const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const Schema = struct {
    allocator: Allocator,
    query_type: ?*types.ObjectType = null,
    mutation_type: ?*types.ObjectType = null,
    subscription_type: ?*types.ObjectType = null,
    types: std.StringHashMap(*types.ObjectType),
    enums: std.StringHashMap(*types.EnumType),
    input_objects: std.StringHashMap(*types.InputObjectType),

    pub fn init(allocator: Allocator) !Schema {
        return Schema{
            .allocator = allocator,
            .types = std.StringHashMap(*types.ObjectType).init(allocator),
            .enums = std.StringHashMap(*types.EnumType).init(allocator),
            .input_objects = std.StringHashMap(*types.InputObjectType).init(allocator),
        };
    }

    pub fn deinit(self: *Schema) void {
        // Clean up query type
        if (self.query_type) |qt| {
            qt.deinit();
            self.allocator.destroy(qt);
        }

        // Clean up mutation type
        if (self.mutation_type) |mt| {
            mt.deinit();
            self.allocator.destroy(mt);
        }

        // Clean up subscription type
        if (self.subscription_type) |st| {
            st.deinit();
            self.allocator.destroy(st);
        }

        // Clean up all registered types
        var type_it = self.types.iterator();
        while (type_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.types.deinit();

        // Clean up enums
        var enum_it = self.enums.iterator();
        while (enum_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.enums.deinit();

        // Clean up input objects
        var input_it = self.input_objects.iterator();
        while (input_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.input_objects.deinit();
    }

    pub fn setQueryType(self: *Schema, query_type: *types.ObjectType) void {
        self.query_type = query_type;
    }

    pub fn setMutationType(self: *Schema, mutation_type: *types.ObjectType) void {
        self.mutation_type = mutation_type;
    }

    pub fn setSubscriptionType(self: *Schema, subscription_type: *types.ObjectType) void {
        self.subscription_type = subscription_type;
    }

    pub fn addType(self: *Schema, object_type: *types.ObjectType) !void {
        const key = try self.allocator.dupe(u8, object_type.name);
        try self.types.put(key, object_type);
    }

    pub fn addEnum(self: *Schema, enum_type: *types.EnumType) !void {
        const key = try self.allocator.dupe(u8, enum_type.name);
        try self.enums.put(key, enum_type);
    }

    pub fn addInputObject(self: *Schema, input_object: *types.InputObjectType) !void {
        const key = try self.allocator.dupe(u8, input_object.name);
        try self.input_objects.put(key, input_object);
    }

    pub fn getType(self: *const Schema, name: []const u8) ?*types.ObjectType {
        return self.types.get(name);
    }

    pub fn getEnum(self: *const Schema, name: []const u8) ?*types.EnumType {
        return self.enums.get(name);
    }

    pub fn getInputObject(self: *const Schema, name: []const u8) ?*types.InputObjectType {
        return self.input_objects.get(name);
    }

    pub fn validate(self: *const Schema) !void {
        if (self.query_type == null) {
            return error.InvalidSchema;
        }

        // Validate all types have valid field types
        var type_it = self.types.iterator();
        while (type_it.next()) |entry| {
            const obj_type = entry.value_ptr.*;
            var field_it = obj_type.fields.iterator();
            while (field_it.next()) |field_entry| {
                const field = field_entry.value_ptr;
                const type_name = stripTypeModifiers(field.type_name);
                
                // Check if type exists
                if (!self.isValidType(type_name)) {
                    std.debug.print("Invalid type reference: {s} in field {s}.{s}\n", 
                        .{ type_name, obj_type.name, field.name });
                    return error.InvalidSchema;
                }
            }
        }
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

    fn isValidType(self: *const Schema, type_name: []const u8) bool {
        // Check built-in scalars
        if (types.ScalarType.fromString(type_name) != null) {
            return true;
        }

        // Check registered types
        if (self.types.contains(type_name)) {
            return true;
        }

        // Check enums
        if (self.enums.contains(type_name)) {
            return true;
        }

        // Check input objects
        if (self.input_objects.contains(type_name)) {
            return true;
        }

        return false;
    }
};

/// Builder pattern for creating schemas
pub const SchemaBuilder = struct {
    schema: Schema,

    pub fn init(allocator: Allocator) !SchemaBuilder {
        return SchemaBuilder{
            .schema = try Schema.init(allocator),
        };
    }

    pub fn query(self: *SchemaBuilder, query_type: *types.ObjectType) *SchemaBuilder {
        self.schema.setQueryType(query_type);
        return self;
    }

    pub fn mutation(self: *SchemaBuilder, mutation_type: *types.ObjectType) *SchemaBuilder {
        self.schema.setMutationType(mutation_type);
        return self;
    }

    pub fn subscription(self: *SchemaBuilder, subscription_type: *types.ObjectType) *SchemaBuilder {
        self.schema.setSubscriptionType(subscription_type);
        return self;
    }

    pub fn addType(self: *SchemaBuilder, object_type: *types.ObjectType) !*SchemaBuilder {
        try self.schema.addType(object_type);
        return self;
    }

    pub fn addEnum(self: *SchemaBuilder, enum_type: *types.EnumType) !*SchemaBuilder {
        try self.schema.addEnum(enum_type);
        return self;
    }

    pub fn addInputObject(self: *SchemaBuilder, input_object: *types.InputObjectType) !*SchemaBuilder {
        try self.schema.addInputObject(input_object);
        return self;
    }

    pub fn build(self: *SchemaBuilder) !Schema {
        try self.schema.validate();
        return self.schema;
    }
};

test "Schema basic creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var schema = try Schema.init(allocator);
    defer schema.deinit();

    const query_type = try allocator.create(types.ObjectType);
    query_type.* = try types.ObjectType.init(allocator, "Query");
    
    schema.setQueryType(query_type);
    
    try testing.expect(schema.query_type != null);
    try testing.expectEqualStrings("Query", schema.query_type.?.name);
}

test "Schema validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var schema = try Schema.init(allocator);
    defer schema.deinit();

    const query_type = try allocator.create(types.ObjectType);
    query_type.* = try types.ObjectType.init(allocator, "Query");
    
    const field = try types.Field.init(allocator, "hello", "String");
    try query_type.addField(field);
    
    schema.setQueryType(query_type);
    
    try schema.validate();
}
