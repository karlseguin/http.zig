// GraphQL module for httpz
// A complete GraphQL implementation in Zig

pub const graphql = @import("graphql/graphql.zig");
pub const types = @import("graphql/types.zig");
pub const schema = @import("graphql/schema.zig");
pub const parser = @import("graphql/parser.zig");
pub const executor = @import("graphql/executor.zig");
pub const introspection = @import("graphql/introspection.zig");
pub const httpz_handler = @import("graphql/httpz_handler.zig");
pub const resolver = @import("graphql/resolver.zig");
pub const introspection_resolver = @import("graphql/introspection_resolver.zig");

// Re-export commonly used types
pub const GraphQL = graphql.GraphQL;
pub const GraphQLRequest = graphql.GraphQLRequest;
pub const GraphQLResponse = graphql.GraphQLResponse;
pub const GraphQLError = graphql.GraphQLError;
pub const Schema = schema.Schema;
pub const SchemaBuilder = schema.SchemaBuilder;
pub const Value = types.Value;
pub const Field = types.Field;
pub const ObjectType = types.ObjectType;
pub const EnumType = types.EnumType;
pub const InputObjectType = types.InputObjectType;
pub const Argument = types.Argument;
pub const GraphQLHandler = httpz_handler.GraphQLHandler;

test {
    @import("std").testing.refAllDecls(@This());
}
