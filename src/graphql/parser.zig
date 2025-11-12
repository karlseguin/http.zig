const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const OperationType = enum {
    Query,
    Mutation,
    Subscription,
};

pub const SelectionKind = enum {
    Field,
    FragmentSpread,
    InlineFragment,
};

pub const Selection = struct {
    kind: SelectionKind,
    name: []const u8,
    alias: ?[]const u8 = null,
    arguments: std.StringHashMap(types.Value),
    selections: std.ArrayList(Selection),
    allocator: Allocator,

    pub fn deinit(self: *Selection) void {
        self.allocator.free(self.name);
        if (self.alias) |a| {
            self.allocator.free(a);
        }
        
        var arg_it = self.arguments.iterator();
        while (arg_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.arguments.deinit();
        
        for (self.selections.items) |*sel| {
            sel.deinit();
        }
        self.selections.deinit(self.allocator);
    }
};

pub const Operation = struct {
    operation_type: OperationType,
    name: ?[]const u8 = null,
    selections: std.ArrayList(Selection),
    allocator: Allocator,

    pub fn deinit(self: *Operation) void {
        if (self.name) |n| {
            self.allocator.free(n);
        }
        for (self.selections.items) |*sel| {
            sel.deinit();
        }
        self.selections.deinit(self.allocator);
    }
};

pub const Document = struct {
    operations: std.ArrayList(Operation),
    allocator: Allocator,

    pub fn deinit(self: *Document) void {
        for (self.operations.items) |*op| {
            op.deinit();
        }
        self.operations.deinit(self.allocator);
    }
};

pub const Parser = struct {
    source: []const u8,
    position: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{
            .source = source,
            .position = 0,
            .allocator = allocator,
        };
    }

    pub fn parseDocument(self: *Parser) !Document {
        var operations: std.ArrayList(Operation) = .empty;
        
        self.skipWhitespace();
        
        while (self.position < self.source.len) {
            const op = try self.parseOperation();
            try operations.append(self.allocator, op);
            self.skipWhitespace();
        }

        return Document{
            .operations = operations,
            .allocator = self.allocator,
        };
    }

    fn parseOperation(self: *Parser) !Operation {
        self.skipWhitespace();
        
        // Check for operation type keyword
        var operation_type = OperationType.Query;
        var name: ?[]const u8 = null;
        
        if (self.peek()) |c| {
            if (c == '{') {
                // Shorthand query syntax
                operation_type = .Query;
            } else {
                // Parse operation type
                const op_keyword = try self.parseIdentifier();
                if (std.mem.eql(u8, op_keyword, "query")) {
                    operation_type = .Query;
                } else if (std.mem.eql(u8, op_keyword, "mutation")) {
                    operation_type = .Mutation;
                } else if (std.mem.eql(u8, op_keyword, "subscription")) {
                    operation_type = .Subscription;
                } else {
                    return error.ParseError;
                }
                
                self.skipWhitespace();
                
                // Parse optional operation name
                if (self.peek()) |next_c| {
                    if (std.ascii.isAlphabetic(next_c)) {
                        name = try self.parseIdentifier();
                        self.skipWhitespace();
                    }
                }
            }
        }
        
        // Parse selection set
        const selections = try self.parseSelectionSet();
        
        return Operation{
            .operation_type = operation_type,
            .name = name,
            .selections = selections,
            .allocator = self.allocator,
        };
    }

    fn parseSelectionSet(self: *Parser) error{ParseError,OutOfMemory,Overflow,InvalidCharacter}!std.ArrayList(Selection) {
        var selections: std.ArrayList(Selection) = .empty;
        
        try self.expect('{');
        self.skipWhitespace();
        
        while (self.peek()) |c| {
            if (c == '}') {
                self.advance();
                break;
            }
            
            const selection = try self.parseSelection();
            try selections.append(self.allocator, selection);
            self.skipWhitespace();
        }
        
        return selections;
    }

    fn parseSelection(self: *Parser) !Selection {
        self.skipWhitespace();
        
        // Parse field name (with optional alias)
        const first_name = try self.parseIdentifier();
        self.skipWhitespace();
        
        var field_name = first_name;
        var alias: ?[]const u8 = null;
        
        // Check for alias
        if (self.peek()) |c| {
            if (c == ':') {
                self.advance();
                self.skipWhitespace();
                alias = first_name;
                field_name = try self.parseIdentifier();
                self.skipWhitespace();
            }
        }
        
        // Parse arguments
        var arguments = std.StringHashMap(types.Value).init(self.allocator);
        if (self.peek()) |c| {
            if (c == '(') {
                arguments = try self.parseArguments();
                self.skipWhitespace();
            }
        }
        
        // Parse nested selections
        var nested_selections: std.ArrayList(Selection) = .empty;
        if (self.peek()) |c| {
            if (c == '{') {
                nested_selections = try self.parseSelectionSet();
            }
        }
        
        return Selection{
            .kind = .Field,
            .name = field_name,
            .alias = alias,
            .arguments = arguments,
            .selections = nested_selections,
            .allocator = self.allocator,
        };
    }

    fn parseArguments(self: *Parser) !std.StringHashMap(types.Value) {
        var args = std.StringHashMap(types.Value).init(self.allocator);
        
        try self.expect('(');
        self.skipWhitespace();
        
        while (self.peek()) |c| {
            if (c == ')') {
                self.advance();
                break;
            }
            
            const arg_name = try self.parseIdentifier();
            self.skipWhitespace();
            try self.expect(':');
            self.skipWhitespace();
            const value = try self.parseValue();
            
            try args.put(arg_name, value);
            
            self.skipWhitespace();
            if (self.peek()) |next_c| {
                if (next_c == ',') {
                    self.advance();
                    self.skipWhitespace();
                }
            }
        }
        
        return args;
    }

    fn parseValue(self: *Parser) error{ParseError,OutOfMemory,Overflow,InvalidCharacter}!types.Value {
        self.skipWhitespace();
        
        const c = self.peek() orelse return error.ParseError;
        
        // String
        if (c == '"') {
            return types.Value{ .string = try self.parseString() };
        }
        
        // Number
        if (std.ascii.isDigit(c) or c == '-') {
            return try self.parseNumber();
        }
        
        // Boolean or null
        if (std.ascii.isAlphabetic(c)) {
            const ident = try self.parseIdentifier();
            if (std.mem.eql(u8, ident, "true")) {
                return types.Value{ .boolean = true };
            } else if (std.mem.eql(u8, ident, "false")) {
                return types.Value{ .boolean = false };
            } else if (std.mem.eql(u8, ident, "null")) {
                return types.Value.null_value;
            }
            self.allocator.free(ident);
            return error.ParseError;
        }
        
        // List
        if (c == '[') {
            return try self.parseList();
        }
        
        // Object
        if (c == '{') {
            return try self.parseObject();
        }
        
        return error.ParseError;
    }

    fn parseString(self: *Parser) ![]const u8 {
        try self.expect('"');
        const start = self.position;
        
        while (self.peek()) |c| {
            if (c == '"') {
                const str = try self.allocator.dupe(u8, self.source[start..self.position]);
                self.advance();
                return str;
            }
            if (c == '\\') {
                self.advance();
            }
            self.advance();
        }
        
        return error.ParseError;
    }

    fn parseNumber(self: *Parser) !types.Value {
        const start = self.position;
        var is_float = false;
        
        if (self.peek()) |c| {
            if (c == '-') {
                self.advance();
            }
        }
        
        while (self.peek()) |c| {
            if (std.ascii.isDigit(c)) {
                self.advance();
            } else if (c == '.') {
                is_float = true;
                self.advance();
            } else if (c == 'e' or c == 'E') {
                is_float = true;
                self.advance();
                if (self.peek()) |next_c| {
                    if (next_c == '+' or next_c == '-') {
                        self.advance();
                    }
                }
            } else {
                break;
            }
        }
        
        const num_str = self.source[start..self.position];
        
        if (is_float) {
            const f = try std.fmt.parseFloat(f64, num_str);
            return types.Value{ .float = f };
        } else {
            const i = try std.fmt.parseInt(i64, num_str, 10);
            return types.Value{ .int = i };
        }
    }

    fn parseList(self: *Parser) !types.Value {
        var list: std.ArrayList(types.Value) = .empty;
        
        try self.expect('[');
        self.skipWhitespace();
        
        while (self.peek()) |c| {
            if (c == ']') {
                self.advance();
                break;
            }
            
            const value = try self.parseValue();
            try list.append(self.allocator, value);
            
            self.skipWhitespace();
            if (self.peek()) |next_c| {
                if (next_c == ',') {
                    self.advance();
                    self.skipWhitespace();
                }
            }
        }
        
        return types.Value{ .list = try list.toOwnedSlice(self.allocator) };
    }

    fn parseObject(self: *Parser) !types.Value {
        var obj = std.StringHashMap(types.Value).init(self.allocator);
        
        try self.expect('{');
        self.skipWhitespace();
        
        while (self.peek()) |c| {
            if (c == '}') {
                self.advance();
                break;
            }
            
            const key = try self.parseIdentifier();
            self.skipWhitespace();
            try self.expect(':');
            self.skipWhitespace();
            const value = try self.parseValue();
            
            try obj.put(key, value);
            
            self.skipWhitespace();
            if (self.peek()) |next_c| {
                if (next_c == ',') {
                    self.advance();
                    self.skipWhitespace();
                }
            }
        }
        
        return types.Value{ .object = obj };
    }

    fn parseIdentifier(self: *Parser) ![]const u8 {
        const start = self.position;
        
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }
        
        if (start == self.position) {
            return error.ParseError;
        }
        
        return try self.allocator.dupe(u8, self.source[start..self.position]);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            if (std.ascii.isWhitespace(c)) {
                self.advance();
            } else if (c == '#') {
                // Skip comment
                while (self.peek()) |comment_c| {
                    self.advance();
                    if (comment_c == '\n') break;
                }
            } else {
                break;
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        if (self.position >= self.source.len) {
            return null;
        }
        return self.source[self.position];
    }

    fn advance(self: *Parser) void {
        if (self.position < self.source.len) {
            self.position += 1;
        }
    }

    fn expect(self: *Parser, expected: u8) !void {
        const c = self.peek() orelse return error.ParseError;
        if (c != expected) {
            return error.ParseError;
        }
        self.advance();
    }
};

pub fn parse(allocator: Allocator, source: []const u8) !Document {
    var parser = Parser.init(allocator, source);
    return try parser.parseDocument();
}

test "Parse simple query" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const query = "{ hello }";
    var doc = try parse(allocator, query);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.operations.items.len);
    try testing.expectEqual(OperationType.Query, doc.operations.items[0].operation_type);
}

test "Parse query with arguments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const query = 
        \\query {
        \\  user(id: "123") {
        \\    name
        \\    email
        \\  }
        \\}
    ;
    
    var doc = try parse(allocator, query);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 1), doc.operations.items.len);
}
