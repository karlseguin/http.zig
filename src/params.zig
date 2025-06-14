const std = @import("std");

const mem = std.mem;
const Allocator = std.mem.Allocator;

// Similar to KeyValue with two important differences
// 1 - We don't need to normalize (i.e. lowercase) the names, because they're
//     statically defined in code, and presumably, if the param is called "id"
//     then the developer will also fetch it as "id"
// 2 - This is populated from Router, and the way router works is that it knows
//     the values before it knows the names. The addValue and addNames
//     methods reflect how Router uses this.
pub const Params = struct {
    len: usize,
    max: usize,
    names: [*][]const u8,
    values: [*][]const u8,

    pub fn init(allocator: Allocator, max: usize) !Params {
        const allocation = try allocator.alloc([]const u8, 2 * max);
        return .{
            .len = 0,
            .max = max,
            .names = allocation.ptr,
            .values = allocation[max..].ptr,
        };
    }

    pub fn deinit(self: *Params, allocator: Allocator) void {
        allocator.free(self.names[0 .. 2 * self.max]);
    }

    pub fn addValue(self: *Params, value: []const u8) void {
        if (self.len == self.max) {
            return;
        }
        self.values[self.len] = value;
        self.len += 1;
    }

    // It should be impossible for names.len != self.len at this point, but it's
    // a bit dangerous to assume that since self.names is re-used between requests
    // and we don't want to leak anything, so I think enforcing a len of names.len
    // is safer, since names is generally statically defined based on routes setup.
    //
    // `noalias names` as `names` being a pointer inside self.names doesn't make sense,
    //  and memcpy needs this guarantee anyways.
    pub fn addNames(self: *Params, noalias names: [][]const u8) void {
        std.debug.assert(names.len == self.len);
        @memcpy(self.names[0..self.len], names);
    }

    pub fn get(self: *const Params, needle: []const u8) ?[]const u8 {
        const names = self.names[0..self.len];
        for (names, 0..) |name, i| {
            if (mem.eql(u8, name, needle)) {
                return self.values[i];
            }
        }

        return null;
    }

    pub fn reset(self: *Params) void {
        self.len = 0;
    }
};

const t = @import("t.zig");
test "params: get" {
    const allocator = t.allocator;
    var params = try Params.init(allocator, 10);
    var names = [_][]const u8{ "over", "duncan" };
    params.addValue("9000");
    params.addValue("idaho");
    params.addNames(names[0..]);

    try t.expectEqual("9000", params.get("over").?);
    try t.expectEqual("idaho", params.get("duncan").?);

    params.reset();
    try t.expectEqual(null, params.get("over"));
    try t.expectEqual(null, params.get("duncan"));

    params.addValue("!9000!");
    params.addNames(names[0..1]);
    try t.expectEqual("!9000!", params.get("over").?);

    params.deinit(t.allocator);
}
