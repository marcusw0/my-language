const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TypeID = u32;

pub const PrimitiveType = enum {
    bool,
    u8,
    u16,
    u32,
    u64,
    f16,
    f32,
    f64,
    err,
};

pub const SemanticType = union(enum) {
    primitive: PrimitiveType,
    optional: TypeID,
    err_union: struct {
        success: TypeID,
        err: TypeID,
    },
};

pub const primitive_types = std.StaticStringMap(PrimitiveType).initComptime(.{
    .{ "bool", .bool },
    .{ "u8", .u8 },
    .{ "u16", .u16 },
    .{ "u32", .u32 },
    .{ "u64", .u64 },
    .{ "f16", .f16 },
    .{ "f32", .f32 },
    .{ "f64", .f64 },
    .{ "error", .err },
});

pub fn isPrimitiveType(ident: []const u8) bool {
    return primitive_types.has(ident);
}

pub const TypeTable = struct {
    entries: std.ArrayList(SemanticType) = .empty,

    pub fn init(allocator: Allocator) !TypeTable {
        var table: TypeTable = .{};
        errdefer table.deinit(allocator);

        // Primitive IDs match their enum values in this initial array prefix.
        for (std.meta.tags(PrimitiveType)) |primitive| {
            try table.entries.append(allocator, .{
                .primitive = primitive,
            });
        }

        return table;
    }

    pub fn deinit(self: *TypeTable, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};
