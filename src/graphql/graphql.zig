const std = @import("std");
const Allocator = std.mem.Allocator;

pub const types = @import("types.zig");
pub const schema = @import("schema.zig");
pub const parser = @import("parser.zig");
pub const executor = @import("executor.zig");
pub const introspection = @import("introspection.zig");

pub const GraphQLError = error{
    ParseError,
    ValidationError,
    ExecutionError,
    InvalidSchema,
    TypeMismatch,
    FieldNotFound,
    ArgumentError,
    OutOfMemory,
};

pub const ErrorLocation = struct {
    line: usize,
    column: usize,
};

pub const GraphQLErrorInfo = struct {
    message: []const u8,
    locations: ?[]ErrorLocation = null,
    path: ?[][]const u8 = null,
};

pub const GraphQLResponse = struct {
    data: ?std.json.Value = null,
    errors: ?[]GraphQLErrorInfo = null,
    allocator: Allocator,

    pub fn deinit(self: *GraphQLResponse) void {
        if (self.errors) |errs| {
            for (errs) |err| {
                self.allocator.free(err.message);
                if (err.locations) |locs| {
                    self.allocator.free(locs);
                }
                if (err.path) |p| {
                    for (p) |segment| {
                        self.allocator.free(segment);
                    }
                    self.allocator.free(p);
                }
            }
            self.allocator.free(errs);
        }
    }

    pub fn toJson(self: *const GraphQLResponse, allocator: Allocator) ![]const u8 {
        var string: std.ArrayList(u8) = .empty;
        defer string.deinit(allocator);
        
        try std.json.stringify(self, .{}, string.writer(allocator));
        return string.toOwnedSlice(allocator);
    }
};

pub const GraphQLRequest = struct {
    query: []const u8,
    operation_name: ?[]const u8 = null,
    variables: ?std.json.Value = null,
};

/// Main GraphQL execution context
pub const GraphQL = struct {
    allocator: Allocator,
    schema: *schema.Schema,

    pub fn init(allocator: Allocator, gql_schema: *schema.Schema) GraphQL {
        return .{
            .allocator = allocator,
            .schema = gql_schema,
        };
    }

    pub fn execute(
        self: *GraphQL,
        request: GraphQLRequest,
        context: anytype,
    ) !GraphQLResponse {
        // Parse the query
        var parsed_query = parser.parse(self.allocator, request.query) catch |err| {
            const err_msg = try std.fmt.allocPrint(self.allocator, "Parse error: {}", .{err});
            const errors = try self.allocator.alloc(GraphQLErrorInfo, 1);
            errors[0] = .{ .message = err_msg };
            return GraphQLResponse{
                .allocator = self.allocator,
                .errors = errors,
            };
        };
        defer parsed_query.deinit();

        // Execute the query
        const result = try executor.execute(
            self.allocator,
            self.schema,
            &parsed_query,
            request.variables,
            context,
        );

        return result;
    }

    pub fn deinit(self: *GraphQL) void {
        _ = self;
    }
};

test "GraphQL basic initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var gql_schema = try schema.Schema.init(allocator);
    defer gql_schema.deinit();

    var gql = GraphQL.init(allocator, &gql_schema);
    defer gql.deinit();
}
