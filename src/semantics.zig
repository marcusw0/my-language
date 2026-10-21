const std = @import("std");
const tree = @import("ast.zig");
const sym = @import("symbol.zig");
const types = @import("types.zig");
const Token = @import("token.zig").Token;

const SymbolID = sym.SymbolId;
const ValueInfo = sym.SymbolTable.ValueInfo;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const SemanticError = error{
    ExpectedPrimitiveType,
    ExpectedErrorType,
    ExpectedVariability,
    InvalidCharacter,
    UnsupportedRootNode,
};

const AnalyzeError = error{
    AtRootNode,
    ArraySizeMismatch,
    DuplicateSymbol,
    UnknownSymbol,
    ReturnOutsideFunction,
    TypeMismatch,
    VariabilityMismatch,
    UnsupportedExpression,
    UnsupportedNoType,
    IntegerOutOfRange,
} || SemanticError || Allocator.Error;

const TypeID = types.TypeID;

/// Static type and variability facts returned by value-expression checking.
const ExpressionInfo = struct {
    type_id: TypeID,
    variability: tree.Variability,
};

const FuncContext = struct {
    /// Resolved written return annotation; null when the annotation was omitted.
    return_type: ?TypeID,
    /// Written return qualifier; null when no qualifier was supplied.
    return_variability: ?tree.Variability,
};

const CheckContext = struct {
    /// Enclosing function's return contract; null outside a function.
    function: ?FuncContext = null,
};

pub const Analyzer = struct {
    /// Owned semantic type descriptions. TypeIDs index this table's entries.
    types: types.TypeTable,

    /// Allocator used to create and free owned tables and binding arrays.
    allocator: Allocator,

    /// Borrowed AST. The AST and source must outlive this analyzer.
    ast: *const tree.Ast,

    /// Owned declaration records and lexical scopes, including resolved value facts.
    symbols: sym.SymbolTable,

    /// Indexed by Ast.nodes. Retains SymbolIDs for declaration nodes and
    /// resolved identifier uses so later passes can reuse their bindings.
    /// Null means no binding has been recorded for that node.
    node_symbols: []?SymbolID,

    /// Indexed by absolute positions in Ast.parameters.
    /// Retains each parameter's declaration SymbolID; null until registered.
    param_symbols: []?SymbolID,

    pub fn init(allocator: Allocator, ast: *const tree.Ast) !Analyzer {
        var type_table = try types.TypeTable.init(allocator);
        errdefer type_table.deinit(allocator);

        var symbols = try sym.SymbolTable.init(allocator);
        errdefer symbols.deinit(allocator);

        const node_symbols = try allocator.alloc(
            ?SymbolID,
            ast.nodes.items.len,
        );
        errdefer allocator.free(node_symbols);
        @memset(node_symbols, null);

        const param_symbols = try allocator.alloc(
            ?SymbolID,
            ast.parameters.items.len,
        );
        @memset(param_symbols, null);

        return .{
            .types = type_table,
            .allocator = allocator,
            .ast = ast,
            .symbols = symbols,
            .node_symbols = node_symbols,
            .param_symbols = param_symbols,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        self.allocator.free(self.param_symbols);
        self.allocator.free(self.node_symbols);
        self.types.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
    }

    /// Visits root function declarations; other root node kinds are currently unsupported.
    pub fn analyze(self: *Analyzer) !void {
        const start = self.ast.roots.start;
        const length = self.ast.roots.len;
        const roots = self.ast.extra.items[start..][0..length];
        for (roots) |val| {
            const node = self.ast.nodes.items[val];
            switch (node) {
                .func_lit => {
                    try self.checkFunction(val);
                },
                else => return AnalyzeError.UnsupportedRootNode,
            }
        }
    }

    fn checkFunction(self: *Analyzer, index: u32) AnalyzeError!void {
        const func = self.ast.nodes.items[index].func_lit;
        const name = self.ast.tokenText(func.signature.name);

        const fn_id = try self.symbols.define(
            self.allocator,
            name,
            .{ .func = index },
            null,
        );
        self.node_symbols[index] = fn_id;

        try self.symbols.enterScope(self.allocator);
        defer self.symbols.leaveScope() catch unreachable;

        if (func.signature.args) |args| {
            const parameters = self.ast.parameters.items[args.start..][0..args.len];
            for (parameters, 0..) |parameter, position| {
                if (parameter.variability == null)
                    return AnalyzeError.ExpectedVariability;

                const param_type: TypeID =
                    try self.resolveTypeAnnotation(parameter.type_expr);

                const name_txt = self.ast.tokenText(parameter.name);
                const param_idx: u32 = args.start + @as(u32, @intCast(position));
                const param_id = try self.symbols.define(
                    self.allocator,
                    name_txt,
                    .{ .parameter = param_idx },
                    .{
                        .type_id = param_type,
                        .variability = parameter.variability.?,
                    },
                );

                self.param_symbols[param_idx] = param_id;
            }
        }
        const return_type: ?TypeID =
            if (func.signature.return_type) |type_expr|
                try self.resolveTypeAnnotation(type_expr)
            else
                null;
        if (return_type) |exists| {
            _ = exists;
            if (func.signature.return_variability == null) {
                return AnalyzeError.ExpectedVariability;
            }
        }

        const context = CheckContext{
            .function = .{
                .return_type = return_type,
                .return_variability = func.signature.return_variability,
            },
        };
        try self.checkBlock(func.body, context);
    }

    /// Visits a block's statements using the caller's active scope and checking context.
    fn checkBlock(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!void {
        const block = self.ast.nodes.items[index].block;
        const statements = self.ast.extra.items[block.statements.start..][0..block.statements.len];
        for (statements) |idx| {
            try self.checkStatement(idx, context);
        }
    }

    /// Checks preceding statements and returns the final node for value checking.
    /// The caller owns the block's scope. Early returns need flow analysis first.
    fn checkValueBlockStatements(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!u32 {
        const block = switch (self.ast.nodes.items[index]) {
            .block => |block| block,
            else => return error.UnsupportedExpression,
        };
        const statements = self.ast.extra.items[block.statements.start..][0..block.statements.len];
        if (statements.len == 0) return error.UnsupportedExpression;

        for (statements[0 .. statements.len - 1]) |statement| {
            if (self.ast.nodes.items[statement] == .return_expr) {
                return error.UnsupportedExpression;
            }
            try self.checkStatement(statement, context);
        }
        return statements[statements.len - 1];
    }

    /// A value block yields its final expression, including its written semicolon.
    fn checkValueBlock(
        self: *Analyzer,
        index: u32,
        expected_type: ?TypeID,
        context: CheckContext,
    ) AnalyzeError!ExpressionInfo {
        try self.symbols.enterScope(self.allocator);
        defer self.symbols.leaveScope() catch unreachable;

        const value = try self.checkValueBlockStatements(index, context);
        return self.checkExpression(value, expected_type, context);
    }

    /// Discovers a branch's result type with its local declarations in scope.
    fn valueBlockTypeHint(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!?TypeID {
        try self.symbols.enterScope(self.allocator);
        defer self.symbols.leaveScope() catch unreachable;

        const value = try self.checkValueBlockStatements(index, context);
        return self.expressionTypeHint(value, context);
    }

    /// Returns expression facts and retains bindings for resolved identifier uses.
    /// expected_type supplies context for integer literals; identifier facts come from symbols.
    /// context carries the enclosing function's return contract through child expressions.
    /// Several expression branches are still placeholders.
    fn checkExpression(
        self: *Analyzer,
        index: u32,
        expected_type: ?TypeID,
        context: CheckContext,
    ) AnalyzeError!ExpressionInfo {
        const node = self.ast.nodes.items[index];
        switch (node) {
            .identifier => |ident| {
                const name = self.ast.tokenText(ident.tok_index);
                const sym_id: ?sym.SymbolId = self.symbols.resolve(name);
                if (sym_id) |id| {
                    self.node_symbols[index] = id;
                } else {
                    return error.UnknownSymbol;
                }
                const symbol = self.symbols.symbols.items[sym_id.?];
                if (symbol.value_info) |info| {
                    return .{
                        .type_id = info.type_id,
                        .variability = info.variability,
                    };
                } else {
                    return error.UnsupportedExpression;
                }
            },
            .integer => |integer| {
                const value = integer.value;
                const expected_id = expected_type orelse
                    return error.UnsupportedNoType;
                const expected = self.types.entries.items[expected_id];

                switch (expected) {
                    .primitive => |primitive| {
                        switch (primitive) {
                            .u8 => {
                                if (std.math.cast(u8, value) == null)
                                    return error.IntegerOutOfRange;

                                return .{
                                    .type_id = expected_id,
                                    .variability = .uniform,
                                };
                            },
                            .u16 => {
                                if (std.math.cast(u16, value) == null)
                                    return error.IntegerOutOfRange;

                                return .{
                                    .type_id = expected_id,
                                    .variability = .uniform,
                                };
                            },
                            .u32 => {
                                if (std.math.cast(u32, value) == null)
                                    return error.IntegerOutOfRange;

                                return .{
                                    .type_id = expected_id,
                                    .variability = .uniform,
                                };
                            },
                            .u64 => {
                                if (std.math.cast(u64, value) == null)
                                    return error.IntegerOutOfRange;

                                return .{
                                    .type_id = expected_id,
                                    .variability = .uniform,
                                };
                            },
                            else => return error.UnsupportedExpression,
                        }
                    },
                    else => return error.UnsupportedExpression,
                }
            },
            .string_lit => return error.UnsupportedExpression,
            .array_lit => |array| {
                const elements = self.ast.extra.items[array.elements.start..][0..array.elements.len];

                const elements_len = @as(u32, @intCast(elements.len));
                const declared_length = array.length;

                if (elements_len == 0) {
                    return error.UnsupportedExpression;
                }
                if (elements_len != declared_length) {
                    return error.ArraySizeMismatch;
                }

                const elements_type: TypeID =
                    try self.resolveTypeAnnotation(array.array_type);

                var elements_variability: tree.Variability = undefined;

                for (elements, 0..) |element, i| {
                    const exp_info = try self.checkExpression(element, elements_type, context);

                    if (i == 0) {
                        elements_variability = exp_info.variability;
                    }
                    if (elements_type != exp_info.type_id) {
                        return error.TypeMismatch;
                    }
                    if (exp_info.variability != elements_variability) {
                        return error.VariabilityMismatch;
                    }
                }

                const semantic_type: types.SemanticType = .{ .array = .{
                    .element_type = elements_type,
                    .len = declared_length,
                } };
                const entry = self.types.findEntry(semantic_type);
                if (entry) |id| {
                    return .{
                        .type_id = id,
                        .variability = elements_variability,
                    };
                }

                const new_id: TypeID = @intCast(self.types.entries.items.len);
                try self.types.entries.append(self.allocator, semantic_type);

                return .{
                    .type_id = new_id,
                    .variability = elements_variability,
                };
            },
            .prefix => |prefix| {
                switch (prefix.operator) {
                    .bang => {
                        const type_id = self.types.primitiveId(.bool);
                        const right_info =
                            try self.checkExpression(prefix.right, type_id, context);

                        if (right_info.type_id != type_id) {
                            return error.TypeMismatch;
                        }

                        return .{
                            .type_id = type_id,
                            .variability = right_info.variability,
                        };
                    },
                    // TODO
                    .minus => return error.UnsupportedExpression,
                    else => return error.UnsupportedExpression,
                }
            },
            .infix => |infix| {
                const is_comparison = switch (infix.operator) {
                    .plus, .minus, .asterisk, .slash => false,
                    .lt, .gt, .eq, .not_eq => true,
                    else => return error.UnsupportedExpression,
                };

                // Arithmetic can inherit its destination's type.
                // A comparison's bool result does not determine its operand type.
                var operand_hint: ?TypeID =
                    if (is_comparison) null else expected_type;

                for ([_]u32{ infix.left, infix.right }) |operand| {
                    if (try self.expressionTypeHint(operand, context)) |hint| {
                        if (operand_hint) |known| {
                            if (known != hint) {
                                return error.TypeMismatch;
                            }
                        } else {
                            operand_hint = hint;
                        }
                    }
                }

                const operand_id = operand_hint orelse
                    return error.UnsupportedNoType;

                const left_info =
                    try self.checkExpression(infix.left, operand_id, context);
                const right_info =
                    try self.checkExpression(infix.right, operand_id, context);

                if (left_info.type_id != operand_id or
                    right_info.type_id != operand_id)
                {
                    return error.TypeMismatch;
                }
                if (left_info.variability != right_info.variability) {
                    return error.VariabilityMismatch;
                }

                const operand_type = self.types.entries.items[operand_id];
                const primitive = switch (operand_type) {
                    .primitive => |primitive| primitive,
                    else => return error.ExpectedPrimitiveType,
                };

                switch (primitive) {
                    .u8, .u16, .u32, .u64 => {},

                    .bool, .err => {
                        if (infix.operator != .eq and infix.operator != .not_eq) {
                            return error.UnsupportedExpression;
                        }
                    },

                    else => return error.UnsupportedExpression,
                }

                return .{
                    .type_id = if (is_comparison)
                        self.types.primitiveId(.bool)
                    else
                        operand_id,
                    .variability = left_info.variability,
                };
            },
            .index_expr => |index_expr| {
                const target = try self.checkExpression(index_expr.target, null, context);
                const prim_id = self.types.primitiveId(.u32);
                const index_parameter = try self.checkExpression(index_expr.index, prim_id, context);

                if (prim_id != index_parameter.type_id) {
                    return error.TypeMismatch;
                }
                if (index_parameter.variability != .uniform) {
                    return error.VariabilityMismatch;
                }

                const semantic_type = self.types.entries.items[target.type_id];
                if (semantic_type != .array) {
                    return error.UnsupportedExpression;
                }

                return .{
                    .type_id = semantic_type.array.element_type,
                    .variability = target.variability,
                };
            },
            .if_expr => |conditional| {
                const alternative = conditional.alternative orelse
                    return error.UnsupportedExpression;
                const bool_id = self.types.primitiveId(.bool);
                const condition = try self.checkExpression(conditional.condition, bool_id, context);
                if (condition.type_id != bool_id) return error.TypeMismatch;
                if (condition.variability != .uniform) return error.VariabilityMismatch;

                const result_type = expected_type orelse
                    try self.expressionTypeHint(index, context);
                const consequence = try self.checkValueBlock(conditional.consequence, result_type, context);
                const other = try self.checkValueBlock(
                    alternative,
                    result_type orelse consequence.type_id,
                    context,
                );
                try checkAssignable(.{
                    .type_id = consequence.type_id,
                    .variability = consequence.variability,
                }, other);
                return consequence;
            },
            .call => return error.UnsupportedExpression,
            else => return error.UnsupportedExpression,
        }
    }

    fn expressionTypeHint(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!?TypeID {
        switch (self.ast.nodes.items[index]) {
            .integer => return null,

            .if_expr => |conditional| {
                const alternative = conditional.alternative orelse
                    return error.UnsupportedExpression;
                const left = try self.valueBlockTypeHint(conditional.consequence, context);
                const right = try self.valueBlockTypeHint(alternative, context);
                if (left) |left_id| {
                    if (right) |right_id| {
                        if (left_id != right_id) return error.TypeMismatch;
                    }
                    return left_id;
                }
                return right;
            },

            .infix => |infix| {
                switch (infix.operator) {
                    .plus, .minus, .asterisk, .slash => {
                        const left = try self.expressionTypeHint(infix.left, context);
                        const right = try self.expressionTypeHint(infix.right, context);

                        if (left) |left_id| {
                            if (right) |right_id| {
                                if (left_id != right_id) {
                                    return error.TypeMismatch;
                                }
                            }
                            return left_id;
                        }

                        return right;
                    },

                    .lt, .gt, .eq, .not_eq => return self.types.primitiveId(.bool),

                    else => return error.UnsupportedExpression,
                }
            },

            else => return (try self.checkExpression(index, null, context)).type_id,
        }
    }

    fn checkStatement(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!void {
        const statement = self.ast.nodes.items[index];
        switch (statement) {
            .var_decl => |var_node| {
                var var_type: ?TypeID = null;
                if (var_node.type_expr) |type_expr| {
                    var_type = try self.resolveTypeAnnotation(type_expr);
                }

                const decl_info = try self.checkExpression(var_node.initializer, var_type, context);

                const val_info: ValueInfo = .{
                    .type_id = var_type orelse decl_info.type_id,
                    .variability = var_node.variability,
                };
                try checkAssignable(val_info, decl_info);

                const name = self.ast.tokenText(var_node.name);
                const id = try self.symbols.define(
                    self.allocator,
                    name,
                    .{ .variable = index },
                    val_info,
                );

                self.node_symbols[index] = id;
            },

            .func_lit => try self.checkFunction(index),

            .return_expr => try self.checkReturn(index, context),

            .block => {
                try self.symbols.enterScope(self.allocator);
                defer self.symbols.leaveScope() catch unreachable;

                try self.checkBlock(index, context);
            },

            .optional, .err_union => return error.UnsupportedExpression,

            .identifier,
            .integer,
            .string_lit,
            .array_lit,
            .infix,
            .index_expr,
            .prefix,
            .call,
            .if_expr,
            => _ = try self.checkExpression(index, null, context),
        }
    }

    /// Checks function context and the returned expression.
    fn checkReturn(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!void {
        const function = context.function orelse
            return error.ReturnOutsideFunction;

        const return_type = function.return_type orelse
            return error.UnsupportedNoType;

        const return_variability = function.return_variability orelse
            return error.ExpectedVariability;

        const returned = self.ast.nodes.items[index].return_expr;
        const actual = try self.checkExpression(
            returned.expression,
            function.return_type,
            context,
        );

        const expected: ValueInfo = .{
            .type_id = return_type,
            .variability = return_variability,
        };

        try checkAssignable(expected, actual);
    }

    /// Resolves an annotation node in Ast.nodes to a shared semantic TypeID.
    /// Reuses existing compound descriptions or appends a new one when absent.
    fn resolveTypeAnnotation(self: *Analyzer, index: u32) AnalyzeError!TypeID {
        switch (self.ast.nodes.items[index]) {
            .identifier => |ident| {
                const type_txt = self.ast.tokenText(ident.tok_index);
                const prim = types.primitive_types.get(type_txt) orelse
                    return error.ExpectedPrimitiveType;

                return self.types.primitiveId(prim);
            },
            .optional => |optional| {
                const type_opt = try self.resolveTypeAnnotation(optional.child);
                const requested: types.SemanticType = .{
                    .optional = type_opt,
                };
                const type_id = self.types.findEntry(requested);
                if (type_id) |id| {
                    return id;
                } else {
                    const new_id = self.types.entries.items.len;
                    try self.types.entries.append(self.allocator, requested);
                    return @as(types.TypeID, @intCast(new_id));
                }
            },
            .err_union => |err_union| {
                const type_success = try self.resolveTypeAnnotation(err_union.success);
                const fail = switch (self.ast.nodes.items[err_union.err]) {
                    .identifier => |ident| ident,
                    else => return error.ExpectedErrorType,
                };
                const error_type = types.primitive_types.get(self.ast.tokenText(fail.tok_index)) orelse
                    return error.ExpectedErrorType;
                if (error_type != .err) {
                    return error.ExpectedErrorType;
                }
                const requested: types.SemanticType = .{
                    .err_union = type_success,
                };
                const type_id = self.types.findEntry(requested);
                if (type_id) |id| {
                    return id;
                } else {
                    const new_id = self.types.entries.items.len;
                    try self.types.entries.append(self.allocator, requested);
                    return @as(types.TypeID, @intCast(new_id));
                }
            },
            else => return error.InvalidCharacter,
        }
    }
};

fn checkAssignable(expected: ValueInfo, actual: ExpressionInfo) AnalyzeError!void {
    if (expected.type_id != actual.type_id) {
        return error.TypeMismatch;
    }
    if (expected.variability != actual.variability) {
        return error.VariabilityMismatch;
    }
}

test "function bodies check declarations and returns" {
    const Lexer = @import("token.zig").Lexer;
    const Parser = @import("parser.zig").Parser;

    const cases = [_]struct {
        source: [:0]const u8,
        expected: ?AnalyzeError,
    }{
        .{
            .source =
            \\fn f() uniform u8 {
            \\   uniform x: u8 = 8;
            \\   return x;
            \\};
            ,
            .expected = null,
        },
        .{
            .source =
            \\fn f() uniform u8 {
            \\   uniform values := [3]u8{ 3, 8, 5 };
            \\   return values[1];
            \\};
            ,
            .expected = null,
        },
        .{
            .source = "fn f(uniform x: u32) uniform u8 { return x; };",
            .expected = error.TypeMismatch,
        },
        .{
            .source = "fn f() uniform u64 { return 18446744073709551615; };",
            .expected = null,
        },
        .{
            .source =
            \\fn f() uniform u8 {
            \\   uniform x: u8 = 256;
            \\   return x;
            \\};
            ,
            .expected = error.IntegerOutOfRange,
        },
        .{
            .source =
            \\fn f() uniform u8 {
            \\   uniform x: u8 = 255;
            \\   return x;
            \\};
            ,
            .expected = null,
        },
        .{
            .source =
            \\fn f(uniform x: u8) uniform u8 {
            \\   uniform copy := x;
            \\   return copy;
            \\};
            ,
            .expected = null,
        },
        .{
            .source =
            \\fn f(uniform x: u32) uniform u8 {
            \\   uniform copy: u8 = x;
            \\   return copy;
            \\};
            ,
            .expected = error.TypeMismatch,
        },
        .{
            .source =
            \\fn f(varying x: u8) uniform u8 {
            \\   return x;
            \\};
            ,
            .expected = error.VariabilityMismatch,
        },
        .{
            .source =
            \\fn f(varying x: u8) uniform u8 {
            \\   uniform copy := x;
            \\   return copy;
            \\};
            ,
            .expected = error.VariabilityMismatch,
        },
        .{
            .source =
            \\fn f() uniform u8 {
            \\   return missing;
            \\};
            ,
            .expected = error.UnknownSymbol,
        },
        .{
            .source =
            \\fn f() uniform u8 {
            \\   uniform x: u8 = 1;
            \\   uniform x: u8 = 2;
            \\   return x;
            \\};
            ,
            .expected = error.DuplicateSymbol,
        },
    };

    for (cases) |case| {
        var lexer = Lexer.init(case.source);
        var ast: tree.Ast = .{
            .source = lexer.buffer,
            .roots = .{ .start = 0, .len = 0 },
        };
        defer ast.deinit(std.testing.allocator);

        var parser = try Parser.init(std.testing.allocator, &ast, &lexer);
        try parser.parse();

        var analyzer = try Analyzer.init(std.testing.allocator, &ast);
        defer analyzer.deinit();

        if (case.expected) |expected| {
            try std.testing.expectError(expected, analyzer.analyze());
        } else {
            try analyzer.analyze();
        }
    }
}

test "if expressions yield scoped branch values" {
    const Lexer = @import("token.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: [:0]const u8,
        expected: ?AnalyzeError,
    }{
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { uniform result: u8 = if (flag) { 3; } else { 8; }; return result; };",
            .expected = null,
        },
        .{
            .source =
            \\fn f(uniform flag: bool) uniform u8 {
            \\    uniform result: u8 = if (flag) {
            \\        uniform local: u8 = 3;
            \\        local;
            \\    } else {
            \\        uniform local: u8 = 8;
            \\        local;
            \\    };
            \\    uniform local: u8 = result;
            \\    return local;
            \\};
            ,
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool, uniform x: u8) uniform u8 { uniform result := if (flag) { 3; } else { x; }; return result; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool, uniform x: u8) uniform u8 { uniform result := if (flag) { x; } else { 3; }; return result; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { uniform result := if (flag) { 3; } else { uniform local: u8 = 8; local; }; return result; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return (if (flag) { 3; } else { 8; }) + 1; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool, uniform x: u8) uniform bool { return (if (flag) { 3; } else { 8; }) < x; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) { if (flag) { 3; } else { 8; } } else { 5; }; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool, varying x: u8, varying y: u8) varying u8 { return if (flag) { x; } else { y; }; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { uniform result: bool = if (flag) { !flag; } else { flag; }; return 1; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: bool, uniform x: u8) uniform u8 { if (flag) { x; } else { x; } return x; };",
            .expected = null,
        },
        .{
            .source = "fn f(uniform flag: u8) uniform u8 { return if (flag) { 3; } else { 8; }; };",
            .expected = error.TypeMismatch,
        },
        .{
            .source = "fn f(varying flag: bool) uniform u8 { return if (flag) { 3; } else { 8; }; };",
            .expected = error.VariabilityMismatch,
        },
        .{
            .source = "fn f(uniform flag: bool, uniform x: u8, uniform y: u16) uniform u8 { return if (flag) { x; } else { y; }; };",
            .expected = error.TypeMismatch,
        },
        .{
            .source = "fn f(uniform flag: bool, uniform x: u8, varying y: u8) uniform u8 { return if (flag) { x; } else { y; }; };",
            .expected = error.VariabilityMismatch,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) { 3; } else { 256; }; };",
            .expected = error.IntegerOutOfRange,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) { 3; }; };",
            .expected = error.UnsupportedExpression,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) {} else { 8; }; };",
            .expected = error.UnsupportedExpression,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) { 3; } else {}; };",
            .expected = error.UnsupportedExpression,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) { uniform local: u8 = 3; } else { 8; }; };",
            .expected = error.UnsupportedExpression,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { uniform result: u8 = if (flag) { return 3; } else { 8; }; return result; };",
            .expected = error.UnsupportedExpression,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) return 3; else { 8; }; };",
            .expected = error.UnsupportedExpression,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) { return 1; 3; } else { 8; }; };",
            .expected = error.UnsupportedExpression,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { uniform result := if (flag) { 3; } else { 8; }; return result; };",
            .expected = error.UnsupportedNoType,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { return if (flag) { uniform local: u8 = 3; local; } else { local; }; };",
            .expected = error.UnknownSymbol,
        },
        .{
            .source = "fn f(uniform flag: bool) uniform u8 { uniform result: u8 = if (flag) { uniform local: u8 = 3; local; } else { 8; }; return local; };",
            .expected = error.UnknownSymbol,
        },
    };

    for (cases) |case| {
        var lexer = Lexer.init(case.source);
        var ast: tree.Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
        defer ast.deinit(allocator);
        var parser = try Parser.init(allocator, &ast, &lexer);
        try parser.parse();

        var analyzer = try Analyzer.init(allocator, &ast);
        defer analyzer.deinit();
        if (case.expected) |expected| {
            try std.testing.expectError(expected, analyzer.analyze());
        } else {
            try analyzer.analyze();
        }
        try std.testing.expectEqual(@as(u32, 0), analyzer.symbols.current);
    }
}

test "array literals resolve element type and length" {
    const Lexer = @import("token.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const allocator = std.testing.allocator;

    var lexer = Lexer.init("[3]u8{ 3, 8, 5 };");
    var ast: tree.Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer ast.deinit(allocator);
    var parser = try Parser.init(allocator, &ast, &lexer);
    try parser.parse();

    var analyzer = try Analyzer.init(allocator, &ast);
    defer analyzer.deinit();
    const root = ast.extra.items[ast.roots.start];
    const info = try analyzer.checkExpression(root, null, .{});
    const array_type = analyzer.types.entries.items[info.type_id].array;

    try std.testing.expectEqual(@as(u32, 3), array_type.len);
    try std.testing.expectEqual(
        types.PrimitiveType.u8,
        analyzer.types.entries.items[array_type.element_type].primitive,
    );
    try std.testing.expectEqual(tree.Variability.uniform, info.variability);
}

test "function annotations validate parameter records and return types" {
    const Lexer = @import("token.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const cases = [_]struct { source: [:0]const u8, expected: ?SemanticError }{
        .{ .source = "fn first(uniform x: u8, varying y: f64) uniform u8!error {}; fn second(varying z: bool) varying ?u8 {};", .expected = null },
        .{ .source = "fn empty() {};", .expected = null },
        .{ .source = "fn bad(uniform x: banana) uniform u8 {};", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() varying banana {};", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() uniform ?banana {};", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() varying u8!f64 {};", .expected = error.ExpectedErrorType },
        .{ .source = "fn bad() uniform u8!banana {};", .expected = error.ExpectedErrorType },
    };
    for (cases) |case| {
        var lexer = Lexer.init(case.source);
        var ast: tree.Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
        defer ast.deinit(std.testing.allocator);
        var parser = try Parser.init(std.testing.allocator, &ast, &lexer);
        try parser.parse();

        var analyzer = try Analyzer.init(std.testing.allocator, &ast);
        defer analyzer.deinit();
        if (case.expected) |expected| {
            try std.testing.expectError(expected, analyzer.analyze());
        } else {
            try analyzer.analyze();
        }
    }
}

test "function annotations require explicit variability" {
    const Lexer = @import("token.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const cases = [_]struct { source: [:0]const u8, expected: ?SemanticError }{
        .{ .source = "fn f(uniform x: u8, varying y: u8) varying u8 {};", .expected = null },
        .{ .source = "fn f() uniform u8 {};", .expected = null },
        .{ .source = "fn f() uniform ?u8 {};", .expected = null },
        .{ .source = "fn f() varying ?u8 {};", .expected = null },
        .{ .source = "fn f() uniform u8!error {};", .expected = null },
        .{ .source = "fn f() varying u8!error {};", .expected = null },
        .{ .source = "fn f(uniform x: u8) {};", .expected = null },
        .{ .source = "fn f() {};", .expected = null },
        .{ .source = "fn f(x: u8) uniform u8 {};", .expected = error.ExpectedVariability },
        .{ .source = "fn f(uniform x: u8, y: u8) uniform u8 {};", .expected = error.ExpectedVariability },
        .{ .source = "fn f() u8 {};", .expected = error.ExpectedVariability },
        .{ .source = "fn f() ?u8 {};", .expected = error.ExpectedVariability },
        .{ .source = "fn f() u8!error {};", .expected = error.ExpectedVariability },
        .{ .source = "fn f(uniform x: u8) u8 {};", .expected = error.ExpectedVariability },
    };
    for (cases) |case| {
        var lexer = Lexer.init(case.source);
        var ast: tree.Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
        defer ast.deinit(std.testing.allocator);
        var parser = try Parser.init(std.testing.allocator, &ast, &lexer);
        try parser.parse();

        var analyzer = try Analyzer.init(std.testing.allocator, &ast);
        defer analyzer.deinit();
        if (case.expected) |expected| {
            try std.testing.expectError(expected, analyzer.analyze());
        } else {
            try analyzer.analyze();
        }
    }
}
