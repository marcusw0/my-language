const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Ast = ast.Ast;

const ScopeId = u32;
const SymbolId = u32;

const SymbolError = error{
    AtRootNode,
    DuplicateSymbol,
} || Allocator.Error;

pub const SymbolTable = struct {
    symbols: std.ArrayList(Symbol) = .empty,
    scope: std.ArrayList(Scope) = .empty,
    current: ScopeId,

    pub const DeclarationRef = union(enum) {
        variable: u32, // Ast.nodes index of .var_decl
        func: u32, // Ast.nodes index of .func_lit
        parameter: u32, // Ast.paramaters index
    };

    pub const Symbol = struct {
        declaration: DeclarationRef,
        scope: ScopeId,
        name: []const u8,
    };

    pub const Scope = struct {
        parent: ?ScopeId,
        names: std.array_hash_map.String(SymbolId) = .empty,
    };

    pub fn init(allocator: Allocator) !SymbolTable {
        var table: SymbolTable = .{ .current = 0 };
        try table.scope.append(allocator, .{ .parent = null });
        return table;
    }

    pub fn deinit(self: *SymbolTable, allocator: Allocator) void {
        for (self.scope.items) |*scope| {
            scope.names.deinit(allocator);
        }
        self.scope.deinit(allocator);
        self.symbols.deinit(allocator);
        self.* = undefined;
    }

    pub fn enterScope(self: *SymbolTable, allocator: Allocator) !void {
        const id: ScopeId = @intCast(self.scope.items.len);
        try self.scope.append(allocator, .{ .parent = self.current });
        self.current = id;
    }

    pub fn leaveScope(self: *SymbolTable) SymbolError!void {
        const current = self.scope.items[self.current].parent;
        if (current) |parent_id| {
            self.current = parent_id;
        } else {
            return SymbolError.AtRootNode;
        }
    }

    pub fn resolve(self: *const SymbolTable, name: []const u8) ?SymbolId {
        var scope_id: ?ScopeId = self.current;

        while (scope_id) |id| {
            const scope = &self.scope.items[id];

            if (scope.names.get(name)) |symbol_id| {
                return symbol_id;
            }
            scope_id = scope.parent;
        }
        return null;
    }

    pub fn define(
        self: *SymbolTable,
        allocator: Allocator,
        name: []const u8,
        declaration:DeclarationRef,
    ) SymbolError!SymbolId {
        const scope = &self.scope.items[self.current];

        if (scope.names.contains(name)) {
            return error.DuplicateSymbol;
        }
        const prev_len = self.symbols.items.len;
        const id: SymbolId = @intCast(prev_len);

        try self.symbols.append(allocator, .{
            .declaration = declaration,
            .scope = self.current,
            .name = name
        });
        errdefer self.symbols.items.len = prev_len;
        try scope.names.put(allocator, name, id);

        return id;
    }
};

const PrimitiveType = enum {
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
