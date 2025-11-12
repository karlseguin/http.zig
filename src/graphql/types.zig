const std = @import("std");
const Allocator = std.mem.Allocator;

/// GraphQL Type System
pub const TypeKind = enum {
    Scalar,
    Object,
    Interface,
    Union,
    Enum,
    InputObject,
    List,
    NonNull,
};

/// Built-in scalar types
pub const ScalarType = enum {
    Int,
    Float,
    String,
    Boolean,
    ID,
    Custom,

    pub fn fromString(name: []const u8) ?ScalarType {
        if (std.mem.eql(u8, name, "Int")) return .Int;
        if (std.mem.eql(u8, name, "Float")) return .Float;
        if (std.mem.eql(u8, name, "String")) return .String;
        if (std.mem.eql(u8, name, "Boolean")) return .Boolean;
        if (std.mem.eql(u8, name, "ID")) return .ID;
        return null;
    }
};

pub const Value = union(enum) {
    null_value,
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    list: []Value,
    object: std.StringHashMap(Value),

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .list => |list| {
                for (list) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(list);
            },
            .object => |*obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
            .string => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn toJsonValue(self: Value, allocator: Allocator) !std.json.Value {
        return switch (self) {
            .null_value => .null,
            .int => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .boolean => |b| .{ .bool = b },
            .list => |list| blk: {
                var arr = std.json.Array.init(allocator);
                for (list) |item| {
                    try arr.append(try item.toJsonValue(allocator));
                }
                break :blk .{ .array = arr };
            },
            .object => |obj| blk: {
                var json_obj = std.json.ObjectMap.init(allocator);
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try json_obj.put(
                        try allocator.dupe(u8, entry.key_ptr.*),
                        try entry.value_ptr.toJsonValue(allocator),
                    );
                }
                break :blk .{ .object = json_obj };
            },
        };
    }
};

pub const Argument = struct {
    name: []const u8,
    type_name: []const u8,
    default_value: ?Value = null,
    description: ?[]const u8 = null,
    allocator: Allocator,

    pub fn deinit(self: *Argument) void {
        self.allocator.free(self.name);
        self.allocator.free(self.type_name);
        if (self.default_value) |*val| {
            val.deinit(self.allocator);
        }
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
    }
};

// Type-erased resolver function
pub const ResolverFn = *const fn (ctx: *anyopaque) anyerror!Value;

pub const Field = struct {
    name: []const u8,
    type_name: []const u8,
    arguments: std.ArrayList(Argument),
    description: ?[]const u8 = null,
    resolver: ?ResolverFn = null,
    resolver_ctx: ?*anyopaque = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8, type_name: []const u8) !Field {
        return Field{
            .name = try allocator.dupe(u8, name),
            .type_name = try allocator.dupe(u8, type_name),
            .arguments = .empty,
            .allocator = allocator,
            .resolver = null,
            .resolver_ctx = null,
        };
    }

    pub fn deinit(self: *Field) void {
        self.allocator.free(self.name);
        self.allocator.free(self.type_name);
        for (self.arguments.items) |*arg| {
            arg.deinit();
        }
        self.arguments.deinit(self.allocator);
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
    }

    pub fn addArgument(self: *Field, arg: Argument) !void {
        try self.arguments.append(self.allocator, arg);
    }
};

pub const ObjectType = struct {
    name: []const u8,
    fields: std.StringHashMap(Field),
    description: ?[]const u8 = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8) !ObjectType {
        var obj: ObjectType = undefined;
        obj.name = try allocator.dupe(u8, name);
        obj.fields = std.StringHashMap(Field).init(allocator);
        obj.description = null;
        obj.allocator = allocator;
        return obj;
    }

    pub fn deinit(self: *ObjectType) void {
        self.allocator.free(self.name);
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.fields.deinit();
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
    }

    pub fn addField(self: *ObjectType, field: Field) !void {
        const key = try self.allocator.dupe(u8, field.name);
        try self.fields.put(key, field);
    }

    pub fn getField(self: *const ObjectType, name: []const u8) ?*Field {
        return self.fields.getPtr(name);
    }
};

pub const EnumValue = struct {
    name: []const u8,
    value: []const u8,
    description: ?[]const u8 = null,
    deprecated: bool = false,
    deprecation_reason: ?[]const u8 = null,
    allocator: Allocator,

    pub fn deinit(self: *EnumValue) void {
        self.allocator.free(self.name);
        self.allocator.free(self.value);
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
        if (self.deprecation_reason) |reason| {
            self.allocator.free(reason);
        }
    }
};

pub const EnumType = struct {
    name: []const u8,
    values: std.ArrayList(EnumValue),
    description: ?[]const u8 = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8) !EnumType {
        return EnumType{
            .name = try allocator.dupe(u8, name),
            .values = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EnumType) void {
        self.allocator.free(self.name);
        for (self.values.items) |*val| {
            val.deinit();
        }
        self.values.deinit(self.allocator);
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
    }

    pub fn addValue(self: *EnumType, value: EnumValue) !void {
        try self.values.append(self.allocator, value);
    }
};

pub const InputObjectType = struct {
    name: []const u8,
    fields: std.StringHashMap(Argument),
    description: ?[]const u8 = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8) !InputObjectType {
        return InputObjectType{
            .name = try allocator.dupe(u8, name),
            .fields = std.StringHashMap(Argument).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InputObjectType) void {
        self.allocator.free(self.name);
        var it = self.fields.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.fields.deinit();
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
    }

    pub fn addField(self: *InputObjectType, field: Argument) !void {
        const key = try self.allocator.dupe(u8, field.name);
        try self.fields.put(key, field);
    }
};

test "Value creation and conversion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var int_val = Value{ .int = 42 };
    defer int_val.deinit(allocator);

    var str_val = Value{ .string = try allocator.dupe(u8, "hello") };
    defer str_val.deinit(allocator);

    var bool_val = Value{ .boolean = true };
    defer bool_val.deinit(allocator);
}

test "ObjectType creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var obj_type = try ObjectType.init(allocator, "User");
    defer obj_type.deinit();

    const field = try Field.init(allocator, "name", "String");
    try obj_type.addField(field);

    const retrieved = obj_type.getField("name");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("name", retrieved.?.name);
}
