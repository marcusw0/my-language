const std = @import("std");
const tree = @import("ast.zig");
const sym = @import("symbol.zig");
const types = @import("types.zig");
const Token = @import("token.zig").Token;

const SymbolID = sym.SymbolId;
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
    DuplicateSymbol,
    UnknownSymbol,
    ReturnOutsideFunction,
    TypeMismatch,
    VariabilityMismatch,
} || SemanticError || Allocator.Error;

const TypeID = types.TypeID;

const ExpressionInfo = struct {
    type_id: TypeID,
    variability: tree.Variability,
};

const FuncContext = struct {
    return_type: ?TypeID,
    return_variability: ?tree.Variability,
};

const CheckContext = struct {
    function: ?FuncContext = null,
};

pub const Analyzer = struct {
    types: types.TypeTable,
    allocator: Allocator,
    ast: *const tree.Ast,
    symbols: sym.SymbolTable,
    node_symbols: []?SymbolID,
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

    pub fn analyze(self: *Analyzer) !void {
        const start = self.ast.roots.start;
        const length = self.ast.roots.len;
        const roots = self.ast.extra.items[start..][0..length];
        for (roots) |val| {
            const node = self.ast.nodes.items[val];
            switch (node) {
                .func_lit => { try self.checkFunction(val); },
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
            .{ .func = index},
        );
        self.node_symbols[index] = fn_id;

        try self.symbols.enterScope(self.allocator);
        defer self.symbols.leaveScope() catch unreachable;


        if (func.signature.args) |args| {
            const parameters = self.ast.parameters.items[args.start..][0..args.len];
            for (parameters, 0..) |parameter, position| {
                if (parameter.variability == null)
                    return AnalyzeError.ExpectedVariability;

                const param_type: ?TypeID = 
                    try self.resolveTypeAnnotation(parameter.type_expr);

                const name_txt = self.ast.tokenText(parameter.name);
                const param_idx: u32 = args.start + @as(u32, @intCast(position));
                const param_id = try self.symbols.define(
                    self.allocator,
                    name_txt,
                    .{ .parameter = param_idx },
                );
                self.param_symbols[param_idx] = param_id;
            }
        }
        const return_type: ?TypeID =
            if (func.signature.return_type) |type_expr|
                try self.resolveTypeAnnotation(type_expr)
            else
                null;

        const context = CheckContext{
            .function = .{
                .return_type = return_type,
                .return_variability = func.signature.return_variability,
            },
        };
        try self.checkBlock(func.body, context);
    }

    fn checkBlock(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!void {
        const block = self.ast.nodes.items[index].block;
        const statements = self.ast.extra.items[block.statements.start..][0..block.statements.len];
        for (statements) |idx| {
            try self.checkStatement(idx, context);
        }
    }

    fn checkExpression(
        self: *Analyzer,
        index: u32,
        expected_type: ?TypeID,
    ) AnalyzeError!ExpressionInfo {
        _ = self;
        _ = index;
        _ = expected_type;
    }

    fn checkStatement(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!void {
            const statement = self.ast.nodes.items[index];
            switch (statement) {
                .var_decl => |var_node| {
                    if (var_node.type_expr) |type_expr| {
                        try self.resolveTypeAnnotation(type_expr);
                    }
                    try self.checkExpression(var_node.initializer);
                    const name = self.ast.tokenText(var_node.name);
                    const id = try self.symbols.define(
                        self.allocator,
                        name,
                        .{ .variable = index },
                    );
                    self.node_symbols[index] = id;
            },
                .func_lit => {},
                .return_expr => try self.checkReturn(index, context),
                .block => {},
                .optional, .err_union => {},
                .identifier,
                .integer,
                .string_lit,
                .array_lit,
                .infix,
                .index_expr,
                .prefix,
                .call,
                .if_expr,
                => {},
            }

    }

    fn checkReturn(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!void {
        const function = context.function orelse
            return error.ReturnOutsideFunction;

        const returned = self.ast.nodes.items[index].return_expr;
        const actual = try self.checkExpression(
            returned.expression,
            function.return_type,
        );
    }

    fn checkAssignable(self: *Analyzer, index: u32, context: CheckContext) AnalyzeError!void {}

    fn resolveTypeAnnotation(self: *Analyzer, index: u32) AnalyzeError!TypeID {
        switch (self.ast.nodes.items[index]) {
            .identifier => |ident| {
                const type_txt = self.ast.tokenText(ident.tok_index);
                const prim = types.primitive_types.get(type_txt) orelse
                    return error.ExpectedPrimitiveType;

                return @intFromEnum(prim);
            },
            .optional => |optional| {
                const type_id = try self.resolveTypeAnnotation(optional.child);
                return type_id;
            },
            .err_union => |err_union| {
                const type_id = try resolveTypeAnnotation(err_union.success);
                const fail = switch (self.ast.nodes.items[err_union.err]) {
                    .identifier => |ident| ident,
                    else => return error.ExpectedErrorType,
                };
                const error_type = types.primitive_types.get(self.ast.tokenText(fail.tok_index)) orelse
                    return error.ExpectedErrorType;
                if (error_type != .err) {
                    return error.ExpectedErrorType;
                }
                return type_id;
            },
            else => return error.InvalidCharacter,
        }
    }
};

test "function annotations validate parameter records and return types" {
    const Lexer = @import("token.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const cases = [_]struct { source: [:0]const u8, expected: ?SemanticError }{
        .{ .source = "fn first(uniform x: u8, varying y: f64) uniform u8!error { return x; }; fn second(varying z: bool) varying ?u8 { return 1; };", .expected = null },
        .{ .source = "fn empty() { return 1; };", .expected = null },
        .{ .source = "fn bad(uniform x: banana) uniform u8 { return 1; };", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() varying banana { return 1; };", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() uniform ?banana { return 1; };", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() varying u8!f64 { return 1; };", .expected = error.ExpectedErrorType },
        .{ .source = "fn bad() uniform u8!banana { return 1; };", .expected = error.ExpectedErrorType },
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
