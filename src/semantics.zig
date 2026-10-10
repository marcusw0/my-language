const std = @import("std");
const Allocator = std.mem.Allocator;
const tree = @import("ast.zig");
const symbol = @import("symbol.zig");
const token = @import("token.zig").Token;

const SemanticError = error{
    ExpectedPrimitiveType,
    ExpectedErrorType,
    ExpectedVariability,
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
                        if (parameter.variability == null) return SemanticError.ExpectedVariability;
                        try validateTypeAnnotation(ast, parameter.type_expr);
                    }
                }
                if (func.signature.return_type) |returnType| {
                    if (func.signature.return_variability == null) return SemanticError.ExpectedVariability;
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
        if (case.expected) |expected| {
            try std.testing.expectError(expected, EvalFunctions(ast));
        } else {
            try EvalFunctions(ast);
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
        if (case.expected) |expected| {
            try std.testing.expectError(expected, EvalFunctions(ast));
        } else {
            try EvalFunctions(ast);
        }
    }
}
