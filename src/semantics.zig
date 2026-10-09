const std = @import("std");
const Allocator = std.mem.Allocator;
const tree = @import("ast.zig");
const symbol = @import("symbol.zig");
const token = @import("token.zig").Token;

const SemanticError = error{
    ExpectedPrimitiveType,
    ExpectedErrorType,
    InvalidCharacter,
};

pub fn EvalFunctions(ast: tree.Ast) !void {
    const roots = ast.extra.items[ast.roots.start..][0..ast.roots.len];
    for (roots) |value| {
        switch (ast.nodes.items[value]) {
            .func_lit => {
                const func = ast.nodes.items[value].func_lit;
                if (func.signature.args) |args| {
                    const parameters = ast.parameters.items[args.start..][0..args.len];
                    for (parameters) |parameter| {
                        try validateTypeAnnotation(ast, parameter.type_expr);
                    }
                }
                if (func.signature.return_type) |returnType| {
                    try validateTypeAnnotation(ast, returnType);
                }
            },
            else => {}
        }
    }
}

fn validateTypeAnnotation(ast: tree.Ast, index: u32) SemanticError!void {
    switch (ast.nodes.items[index]) {
        .identifier => |ident| {
            if (!symbol.isPrimitiveType(ast.tokenText(ident.tok_index))) {
                return SemanticError.ExpectedPrimitiveType;
            }
        },
        .optional => |optional| {
            try validateTypeAnnotation(ast, optional.child);
        },
        .err_union => |err_union| {
            try validateTypeAnnotation(ast, err_union.success);
            const fail = switch (ast.nodes.items[err_union.err]) {
                .identifier => |ident| ident,
                else => return SemanticError.ExpectedErrorType,
            };
            const error_type = symbol.PrimitiveTypes.get(ast.tokenText(fail.tok_index)) orelse
                return SemanticError.ExpectedErrorType;
            if (error_type != .err) {
                return SemanticError.ExpectedErrorType;
            }
        },
        else => return SemanticError.InvalidCharacter,
    }
}

test "function annotations validate parameter records and return types" {
    const Lexer = @import("token.zig").Lexer;
    const Parser = @import("parser.zig").Parser;
    const cases = [_]struct { source: [:0]const u8, expected: ?SemanticError }{
        .{ .source = "fn first(x u8, y f64) u8!error { return x; }; fn second(z bool) ?u8 { return 1; };", .expected = null },
        .{ .source = "fn empty() { return 1; };", .expected = null },
        .{ .source = "fn bad(x banana) u8 { return 1; };", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() banana { return 1; };", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() ?banana { return 1; };", .expected = error.ExpectedPrimitiveType },
        .{ .source = "fn bad() u8!f64 { return 1; };", .expected = error.ExpectedErrorType },
        .{ .source = "fn bad() u8!banana { return 1; };", .expected = error.ExpectedErrorType },
    };
    for (cases) |case| {
        var lexer = Lexer.init(case.source);
        var ast: tree.Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
        defer ast.deinit(std.testing.allocator);
        var parser = try Parser.init(std.testing.allocator, &ast, &lexer);
        try parser.parse();
        if (case.expected) |expected| {
            try std.testing.expectError(expected, EvalFunctions(ast));
        } else {
            try EvalFunctions(ast);
        }
    }
}
