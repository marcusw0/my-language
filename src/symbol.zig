const std = @import("std");

const primitive_types = enum {
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

pub const PrimitiveTypes = std.StaticStringMap(primitive_types).initComptime(.{
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
    return PrimitiveTypes.has(ident);
}
