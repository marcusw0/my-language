const std = @import("std");
const Allocator = std.mem.Allocator;

/// Index of a semantic type description in TypeTable.entries.
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

/// Resolved type description; compound payloads reference other entries by TypeID.
pub const SemanticType = union(enum) {
    primitive: PrimitiveType,
    /// TypeID of the optional's contained type.
    optional: TypeID,
    /// TypeID of the success type; the failure type is always built-in error.
    err_union: TypeID,
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
    /// Owned descriptions. Preserve entry positions once their IDs are retained.
    entries: std.ArrayList(SemanticType) = .empty,

    /// Seeds primitive entries in enum order so primitive values match their TypeIDs.
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

    /// Finds an optional/error-union entry with the same variant and payload.
    /// Returns its TypeID or null; does not append entries. Primitive requests return null.
    pub fn findEntry(self: *const TypeTable, requested: SemanticType) ?TypeID {
        switch (requested) {
            .optional => |id| {
                for (self.entries.items, 0..) |entry, i| {
                    switch (entry) {
                        .optional => |stored| {
                            if (stored == id) {
                                return @as(TypeID, @intCast(i));
                            }
                        },
                        else => {},

                    }
                }
            },
            .err_union => |id| {
                for (self.entries.items, 0..) |entry, i| {
                    switch (entry) {
                        .err_union => |stored| {
                            if (stored == id) {
                                return @as(TypeID, @intCast(i));
                            }
                        },
                        else => {},
                    }
                }

            },
            else => {},
        }
        return null;
    }
};
