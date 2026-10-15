const std = @import("std");
const types = @import("types.zig");
const ast = @import("ast.zig");
const Ast = ast.Ast;

const Allocator = std.mem.Allocator;

/// Index into SymbolTable.scope.
const ScopeId = u32;
/// Index into SymbolTable.symbols.
pub const SymbolId = u32;

const SymbolError = error{
    AtRootNode,
    DuplicateSymbol,
} || Allocator.Error;

/// Owns symbol/scope records and name-map storage; name bytes are borrowed.
pub const SymbolTable = struct {
    /// Declaration records addressed by SymbolId.
    symbols: std.ArrayList(Symbol) = .empty,
    /// Retained lexical scopes addressed by ScopeId.
    scope: std.ArrayList(Scope) = .empty,
    /// Currently active scope; leaving a scope restores its parent ID.
    current: ScopeId,

    /// Declaration location; the tag selects the AST node or parameter buffer.
    pub const DeclarationRef = union(enum) {
        variable: u32, // Ast.nodes index of .var_decl
        func: u32, // Ast.nodes index of .func_lit
        parameter: u32, // Ast.paramaters index
    };

    /// Resolved type and declared variability for a value declaration.
    pub const ValueInfo = struct {
        type_id: types.TypeID,
        variability: ast.Variability,
    };

    pub const Symbol = struct {
        declaration: DeclarationRef,
        /// Null when resolved value facts have not been recorded for this symbol.
        value_info: ?ValueInfo = null,
        /// Owning lexical scope in SymbolTable.scope.
        scope: ScopeId,
        /// Borrowed name bytes; they must outlive the table and remain unchanged.
        name: []const u8,
    };

    pub const Scope = struct {
        /// Enclosing scope ID; null identifies the root scope.
        parent: ?ScopeId,
        /// Names declared in this scope mapped to their SymbolIds.
        names: std.array_hash_map.String(SymbolId) = .empty,
    };

    /// Creates root scope 0 and makes it the active scope.
    pub fn init(allocator: Allocator) !SymbolTable {
        var table: SymbolTable = .{ .current = 0 };
        try table.scope.append(allocator, .{ .parent = null });
        return table;
    }

    /// Frees owned records and maps; borrowed name bytes are not freed.
    pub fn deinit(self: *SymbolTable, allocator: Allocator) void {
        for (self.scope.items) |*scope| {
            scope.names.deinit(allocator);
        }
        self.scope.deinit(allocator);
        self.symbols.deinit(allocator);
        self.* = undefined;
    }

    /// Appends a child of the active scope and makes that child active.
    pub fn enterScope(self: *SymbolTable, allocator: Allocator) !void {
        const id: ScopeId = @intCast(self.scope.items.len);
        try self.scope.append(allocator, .{ .parent = self.current });
        self.current = id;
    }

    /// Restores the parent scope without deleting records. Fails at the root.
    pub fn leaveScope(self: *SymbolTable) SymbolError!void {
        const current = self.scope.items[self.current].parent;
        if (current) |parent_id| {
            self.current = parent_id;
        } else {
            return SymbolError.AtRootNode;
        }
    }

    /// Searches the active scope, then its parents; null means the name was not found.
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

    /// Registers a declaration in the active scope and returns its symbol-array index.
    /// Rejects duplicates in that scope; declarations in parent scopes may be shadowed.
    /// Borrows name bytes, which the caller must keep alive and unchanged.
    pub fn define(
        self: *SymbolTable,
        allocator: Allocator,
        name: []const u8,
        declaration:DeclarationRef,
        val_info:?ValueInfo,
    ) SymbolError!SymbolId {
        const scope = &self.scope.items[self.current];

        if (scope.names.contains(name)) {
            return error.DuplicateSymbol;
        }
        const prev_len = self.symbols.items.len;
        const id: SymbolId = @intCast(prev_len);

        try self.symbols.append(allocator, .{
            .declaration = declaration,
            .value_info = val_info,
            .scope = self.current,
            .name = name
        });
        errdefer self.symbols.items.len = prev_len;
        try scope.names.put(allocator, name, id);

        return id;
    }
};
