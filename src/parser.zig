const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const tokenizer = @import("token.zig");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").Type;
const Lexer = @import("token.zig").Lexer;
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Node = ast.Node;
const NodeIndex = u32;

const ParseError = error{
    ExpectedExpression,
    ExpectedTerminator,
    ExpectedLeftParen,
    ExpectedLeftBrace,
    ExpectedRightParen,
    ExpectedRightBracket,
    ExpectedRightBrace,
    ExpectedSeparator,
    ExpectedParameterName,
    ExpectedParameterType,
    InvalidCharacter,
} || Allocator.Error || std.fmt.ParseIntError;

const Precedence = enum {
    lowest,
    equals,      // ==
    lessgreater, // > or <
    fallback,    // orelse
    sum,         // +
    product,     // *
    prefix,      // -X or !X
    call,        // myFunction(X)
    index,       // array[index]
};

fn precedence(token: Token) Precedence {
    return switch (token.type) {
        .eq, .not_eq => .equals,
        .lt, .gt => .lessgreater,
        .key_orelse => .fallback,
        .plus, .minus => .sum,
        .asterisk, .slash => .product,
        .lparen => .call,
        .lbracket => .index,
        else => .lowest,
    };
}



pub const Parser = struct {
    tok_idx: usize,
    lexer: *Lexer,
    ast: *Ast,
    allocator: Allocator,

    pub fn init(allocator: Allocator, a: *Ast, l: *Lexer) !Parser {
        var eof: Token = undefined;

        while (true) {
            const token = l.nextToken();
            if (token.type == .eof) { eof = token; break; }
            try a.tokens.append(allocator, token);
        }
        try a.tokens.append(allocator, eof);
        return .{
            .tok_idx = 0,
            .lexer = l,
            .ast = a,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) !void {
        var root_indices: std.ArrayList(NodeIndex) = .empty;
        defer root_indices.deinit(self.allocator);

        while (self.peekToken().type != .eof) {
            const root_idx = try parseStatement(self);
            try root_indices.append(self.allocator, root_idx);
        }
        self.ast.roots = try self.ast.addRange(
            self.allocator,
            root_indices.items,
        );
    }

    fn nextToken(self: *Parser) Token {
        self.tok_idx += 1;
        return self.ast.tokens.items[self.tok_idx - 1];
    }

    fn peekToken(self: *Parser) Token {
        return self.ast.tokens.items[self.tok_idx];
    }
};

fn parseStatement(p: *Parser) ParseError!NodeIndex {
    const token = p.peekToken();

    const index = switch (token.type) {
        .key_return => try parseReturn(p),
        .key_func => try parseFunc(p),
        .key_varying, .key_uniform => try parseVarDecl(p),
        else => try parseExpression(p, .lowest),
    };

    const node_type = p.ast.nodes.items[index];
    switch (node_type) {
        .if_expr => {
            if (p.peekToken().type == .semicolon) {
                return ParseError.InvalidCharacter;
            }
            return index;
        },
        else => {
            if (p.peekToken().type != .semicolon) {
                return ParseError.ExpectedTerminator;
            }
            _ = p.nextToken();
            return index;
        }
    }
}

fn parseVarDecl(p: *Parser) ParseError!NodeIndex {
    const token = p.peekToken();
    const variability = p.ast.assignVariability(token);
    _ = p.nextToken();

    if (p.peekToken().type != .ident) {
        return ParseError.InvalidCharacter;
    }
    const name = @as(u32, @intCast(p.tok_idx));
    _ = p.nextToken();

    if (p.peekToken().type != .colon) {
        return ParseError.ExpectedSeparator;
    }
    _ = p.nextToken();

    var type_expr: ?NodeIndex = null;
    if (p.peekToken().type == .ident) {
        type_expr = try p.ast.addNode(p.allocator, .{
            .identifier = .{ .tok_index = @intCast(p.tok_idx) },
        });
        _ = p.nextToken();
    }
    const tok = p.peekToken();
    if (tok.type != .assign and tok.type != .colon) {
        return ParseError.ExpectedSeparator;
    }

    const mutability = p.ast.assignMutability(tok);
    _ = p.nextToken();

    const val = try parseExpression(p, .lowest);

    return p.ast.addNode(p.allocator, .{
        .var_decl = .{
            .variability = variability,
            .name = name,
            .type_expr = type_expr,
            .mutability = mutability,
            .initializer = val,
        }
    });

}

fn parseExpression(p: *Parser, minimum: Precedence) ParseError!NodeIndex {
    const token = p.peekToken();

    var left_idx: NodeIndex = switch (token.type) {
        .int => try parseIntegerLit(p, token),

        .ident => blk: {
            const index = @as(u32, @intCast(p.tok_idx));
            _ = p.nextToken();
            break :blk try p.ast.addNode(p.allocator, .{
                .identifier = .{ .tok_index = index },
            });
        },

        .string_lit => blk: {
            const index = @as(u32, @intCast(p.tok_idx));
            _ = p.nextToken();
            break :blk try p.ast.addNode(p.allocator, .{
                .string_lit = .{ .tok_index = index },
            });
        },

        .lbracket => try parseArrayLit(p),

        .lparen => blk: {
            _ = p.nextToken(); // Consume '('.
            const inner_idx = try parseExpression(p, .lowest);

            if (p.peekToken().type != .rparen)
                return error.ExpectedRightParen;

            _ = p.nextToken(); // Consume ')'.
            break :blk inner_idx;
        },

        .minus, .bang, .plus => try parsePrefix(p, token),

        .key_if => try parseIf(p),

        .illegal => return ParseError.InvalidCharacter,

        else => return error.ExpectedExpression,
    };

    while (@intFromEnum(precedence(p.peekToken())) >
        @intFromEnum(minimum)) {
        left_idx = switch (p.peekToken().type) {
            .lparen => try parseCall(p, left_idx),
            .lbracket => try parseIndex(p, left_idx),
            else => try parseInfix(p, left_idx),
        };
    }
    return left_idx;
}

fn parseFunc(p: *Parser) ParseError!NodeIndex {
    _ = p.nextToken();

    if (p.peekToken().type != .ident) {
        return ParseError.InvalidCharacter;
    }
    const name = @as(u32, @intCast(p.tok_idx));
    _ = p.nextToken();

    if (p.peekToken().type != .lparen) {
        return ParseError.ExpectedLeftParen;
    }
    _ = p.nextToken();

    var args: ?ast.ParameterRange = null;
    if (p.peekToken().type != .rparen) {
        args = try parseParameters(p);
    }
    if (p.peekToken().type != .rparen) return ParseError.ExpectedRightParen;
    _ = p.nextToken();

    var signature = ast.FuncSignature{
        .name = name,
        .args = args,
        .return_type = null,
        .return_variability = parseVariability(p),
    };

    if (signature.return_variability != null and
        p.peekToken().type != .ident and p.peekToken().type != .question)
    {
        return ParseError.ExpectedParameterType;
    }

    if (p.peekToken().type != .lbrace) {
        switch (p.peekToken().type) {
            .ident => {
                const id = try p.ast.addNode(p.allocator, .{
                    .identifier = .{ .tok_index = @intCast(p.tok_idx) },
                });
                _ = p.nextToken();
                if (p.peekToken().type == .bang) {
                    _ = p.nextToken();
                    if (p.peekToken().type == .ident) {
                        const err = try p.ast.addNode(p.allocator, .{
                            .identifier = .{ .tok_index = @intCast(p.tok_idx) },
                        });
                        signature.return_type = try p.ast.addNode(p.allocator, .{
                            .err_union = .{
                                .success = id,
                                .err = err,
                            }
                        });
                    } else return ParseError.ExpectedParameterType;
                    _ = p.nextToken();
                } else {
                    signature.return_type = id;
                }
            },
            .question => {
                _ = p.nextToken();
                if (p.peekToken().type == .ident) {
                    const id = try p.ast.addNode(p.allocator, .{
                        .identifier = .{ .tok_index = @intCast(p.tok_idx) },
                    });
                    signature.return_type = try p.ast.addNode(p.allocator, .{
                        .optional = .{ .child = id },
                    });
                } else return ParseError.ExpectedParameterType;
                _ = p.nextToken();
            },
            else => return ParseError.InvalidCharacter,
        }
    }

    if (p.peekToken().type != .lbrace) {
        return ParseError.ExpectedLeftBrace;
    }

    const body = try parseBlock(p);

    return try p.ast.addNode(p.allocator, .{
        .func_lit = .{
            .body = body,
            .signature = signature,
        }
    });
}

fn parseVariability(p: *Parser) ?ast.Variability {
    const token = p.peekToken();
    if (token.type != .key_uniform and token.type != .key_varying) return null;
    _ = p.nextToken();
    return p.ast.assignVariability(token);
}

fn parseParameters(p: *Parser) ParseError!ast.ParameterRange {
    const start = p.ast.parameters.items.len;
    errdefer p.ast.parameters.items.len = start;

    if (p.peekToken().type != .rparen) {
        while (true) {
            const variability = parseVariability(p);
            if (p.peekToken().type != .ident) return ParseError.ExpectedParameterName;
            const name = @as(u32, @intCast(p.tok_idx));
            _ = p.nextToken();

            if (p.peekToken().type != .colon) return ParseError.ExpectedSeparator;
            _ = p.nextToken();

            if (p.peekToken().type != .ident) return ParseError.ExpectedParameterType;
            const type_expr = try p.ast.addNode(p.allocator, .{
                .identifier = .{ .tok_index = @intCast(p.tok_idx) },
            });
            _ = p.nextToken();

            try p.ast.parameters.append(p.allocator, .{
                .name = name,
                .type_expr = type_expr,
                .variability = variability,
            });

            if (p.peekToken().type == .rparen) break;
            if (p.peekToken().type == .eof) return ParseError.ExpectedRightParen;
            if (p.peekToken().type != .comma) return ParseError.ExpectedSeparator;
            _ = p.nextToken();
        }
    }

    return .{
        .start = @intCast(start),
        .len = @intCast(p.ast.parameters.items.len - start),
    };
}

fn parseIf(p: *Parser) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.nextToken();
    if (p.peekToken().type != .lparen) return ParseError.ExpectedLeftParen;

    const condition = try parseExpression(p, .lowest);

    if (p.peekToken().type != .lbrace and p.peekToken().type != .key_return) {
        return ParseError.InvalidCharacter;
    }

    const consequence = try parseBlock(p);

    var alternative: ?NodeIndex = null;
    if (p.peekToken().type == .key_else) {
        _ = p.nextToken();

        if (p.peekToken().type != .lbrace and p.peekToken().type != .key_return) {
            return ParseError.InvalidCharacter;
        }
        alternative = try parseBlock(p);

    }
    return try p.ast.addNode(p.allocator, .{
        .if_expr = .{
            .tok_index = index,
            .condition = condition,
            .consequence = consequence,
            .alternative = alternative,
        }
    });
}

fn parseBlock(p: *Parser) ParseError!NodeIndex {
    if (p.peekToken().type == .key_return) {
        return try parseStatement(p);
    }
    if (p.peekToken().type != .lbrace) return ParseError.ExpectedLeftBrace;
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.nextToken();

    var node_indices: std.ArrayList(NodeIndex) = .empty;
    defer node_indices.deinit(p.allocator);

    while (p.peekToken().type != .rbrace and p.peekToken().type != .eof) {
        const node_idx = try parseStatement(p);
        try node_indices.append(p.allocator, node_idx);
    }

    if (p.peekToken().type != .rbrace) return ParseError.ExpectedRightBrace;
    _ = p.nextToken();

    const range = try p.ast.addRange(p.allocator, node_indices.items);

    return try p.ast.addNode(p.allocator, .{
        .block = .{
            .tok_index = index,
            .statements = range,
        }
    });
}

fn parseReturn(p: *Parser) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.nextToken();
    const expression = try parseExpression(p, .lowest);

    return p.ast.addNode(p.allocator, .{
        .return_expr = .{
            .tok_index = index,
            .expression = expression,
        }
    });
}

fn parsePrefix(p: *Parser, token: Token) ParseError!NodeIndex {
    _ = p.nextToken();
    const right = try parseExpression(p, .prefix);
    return try p.ast.addNode(p.allocator, .{
        .prefix = .{
            .operator = token.type,
            .right = right,
        }
    });
}

fn parseExpressionList(p: *Parser, closing: TokenType) ParseError!ast.NodeRange {
    var indices: std.ArrayList(NodeIndex) = .empty;
    defer indices.deinit(p.allocator);

    const expected_closing: ParseError = switch (closing) {
        .rparen => ParseError.ExpectedRightParen,
        .rbracket => ParseError.ExpectedRightBracket,
        else => unreachable,
    };

    if (p.peekToken().type != closing) {
        while (true) {
            if (p.peekToken().type == .eof) return expected_closing;
            const index = try parseExpression(p, .lowest);
            try indices.append(p.allocator, index);

            if (p.peekToken().type == closing) break;
            if (p.peekToken().type == .eof) return expected_closing;
            if (p.peekToken().type != .comma) return ParseError.ExpectedSeparator;
            _ = p.nextToken();
            // As with parameter lists, a trailing comma is not accepted.
            if (p.peekToken().type == closing) return ParseError.ExpectedExpression;
        }
    }
    _ = p.nextToken();
    return try p.ast.addRange(p.allocator, indices.items);
}

fn parseArrayLit(p: *Parser) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.nextToken(); // Consume '['.
    const elements = try parseExpressionList(p, .rbracket);
    return try p.ast.addNode(p.allocator, .{
        .array_lit = .{ .tok_index = index, .elements = elements },
    });
}

fn parseCall(p: *Parser, func: NodeIndex) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.nextToken(); // Consume '('.
    const arguments = try parseExpressionList(p, .rparen);
    return try p.ast.addNode(p.allocator, .{
        .call = .{ .tok_index = index, .func = func, .arguments = arguments },
    });
}

fn parseIndex(p: *Parser, left: NodeIndex) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.nextToken(); // Consume '['.
    const idx = try parseExpression(p, .lowest);
    if (p.peekToken().type != .rbracket) return ParseError.ExpectedRightBracket;
    _ = p.nextToken(); // Consume ']'.
    return try p.ast.addNode(p.allocator, .{
        .index_expr = .{ .tok_index = index, .left = left, .idx = idx },
    });
}

fn parseInfix(p: *Parser, left_idx: NodeIndex) ParseError!NodeIndex {
    const operator = p.peekToken();
    const op_type = operator.type;
    const operator_precedence = precedence(operator);

    _ = p.nextToken(); // Consume the operator.

    const right_idx = try parseExpression(p, operator_precedence);

    return try p.ast.addNode(p.allocator, .{
        .infix = .{
            .left = left_idx,
            .operator = op_type,
            .right = right_idx,
        },
    });
}

fn parseIntegerLit(p: *Parser, token: Token) !NodeIndex {
    const buffer: []const u8 = p.ast.source[token.byte_start..token.byte_end];
    const value = try std.fmt.parseInt(i64, buffer, 0);
    const node: Node = .{ .integer = .{ .value = value } };
    const node_idx = try p.ast.addNode(p.allocator, node);
    _ = p.nextToken();
    return node_idx;
}

test "parse variable declerations" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init("varying foo::7; uniform bar: u8 = 8;");
    var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer a.deinit(allocator);
    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();

    try std.testing.expectEqual(@as(u32, 2), a.roots.len);
    const roots = a.extra.items[a.roots.start..][0..a.roots.len];
    const name = a.nodes.items[roots[0]].var_decl;
    try std.testing.expectEqualStrings("foo", a.tokenText(name.name));
    try std.testing.expectEqual(.varying, name.variability);
    try std.testing.expectEqual(.constant, name.mutability);
    try std.testing.expect(name.type_expr == null);
    try std.testing.expectEqual(@as(i64, 7), a.nodes.items[name.initializer].integer.value);

    const bar = a.nodes.items[roots[1]].var_decl;
    try std.testing.expectEqualStrings("bar", a.tokenText(bar.name));
    try std.testing.expectEqual(.uniform, bar.variability);
    try std.testing.expectEqual(.variable, bar.mutability);
    try std.testing.expect(bar.type_expr != null);
    const type_expr = a.nodes.items[bar.type_expr.?].identifier;
    try std.testing.expectEqualStrings("u8", a.tokenText(type_expr.tok_index));
    try std.testing.expectEqual(@as(i64, 8), a.nodes.items[bar.initializer].integer.value);
    try std.testing.expectEqual(TokenType.eof, parser.peekToken().type);
}

test "parse identifiers strings and nested arrays" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init("name; \"hello\"; []; [1, 2 + 3, [4]];");
    var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer a.deinit(allocator);
    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();

    try std.testing.expectEqual(@as(u32, 4), a.roots.len);
    const roots = a.extra.items[a.roots.start..][0..a.roots.len];
    const name = a.nodes.items[roots[0]].identifier;
    try std.testing.expectEqualStrings("name", a.tokenText(name.tok_index));
    const string = a.nodes.items[roots[1]].string_lit;
    try std.testing.expectEqualStrings("\"hello\"", a.tokenText(string.tok_index));
    try std.testing.expectEqual(@as(u32, 0), a.nodes.items[roots[2]].array_lit.elements.len);

    const array = a.nodes.items[roots[3]].array_lit;
    try std.testing.expectEqualStrings("[", a.tokenText(array.tok_index));
    try std.testing.expectEqual(@as(u32, 3), array.elements.len);
    const elements = a.extra.items[array.elements.start..][0..array.elements.len];
    try std.testing.expectEqual(@as(i64, 1), a.nodes.items[elements[0]].integer.value);
    const sum = a.nodes.items[elements[1]].infix;
    try std.testing.expectEqual(TokenType.plus, sum.operator);
    try std.testing.expectEqual(@as(i64, 2), a.nodes.items[sum.left].integer.value);
    try std.testing.expectEqual(@as(i64, 3), a.nodes.items[sum.right].integer.value);
    const nested = a.nodes.items[elements[2]].array_lit.elements;
    try std.testing.expectEqual(@as(u32, 1), nested.len);
    try std.testing.expectEqual(@as(i64, 4), a.nodes.items[a.extra.items[nested.start]].integer.value);
    try std.testing.expectEqual(TokenType.eof, parser.peekToken().type);
}

test "function signatures retain parameter and return variability" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(
        "fn mixed(uniform count: u32, varying value: u8, plain: bool) varying u8 { return value; }; " ++
        "fn maybe() uniform ?u8 { return 1; }; " ++
        "fn fallible() varying u8!error { return 1; }; " ++
        "fn shared() uniform u8 { return 1; };",
    );
    var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer a.deinit(allocator);
    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();

    try std.testing.expectEqual(@as(u32, 4), a.roots.len);
    const roots = a.extra.items[a.roots.start..][0..a.roots.len];
    const mixed = a.nodes.items[roots[0]].func_lit.signature;
    try std.testing.expectEqualStrings("mixed", a.tokenText(mixed.name));
    try std.testing.expectEqual(.varying, mixed.return_variability.?);
    try std.testing.expectEqualStrings("u8", a.tokenText(a.nodes.items[mixed.return_type.?].identifier.tok_index));
    const args = mixed.args.?;
    try std.testing.expectEqual(@as(u32, 3), args.len);
    const parameters = a.parameters.items[args.start..][0..args.len];
    try std.testing.expectEqualStrings("count", a.tokenText(parameters[0].name));
    try std.testing.expectEqual(.uniform, parameters[0].variability.?);
    try std.testing.expectEqualStrings("u32", a.tokenText(a.nodes.items[parameters[0].type_expr].identifier.tok_index));
    try std.testing.expectEqualStrings("value", a.tokenText(parameters[1].name));
    try std.testing.expectEqual(.varying, parameters[1].variability.?);
    try std.testing.expectEqualStrings("u8", a.tokenText(a.nodes.items[parameters[1].type_expr].identifier.tok_index));
    try std.testing.expectEqualStrings("plain", a.tokenText(parameters[2].name));
    try std.testing.expect(parameters[2].variability == null);
    try std.testing.expectEqualStrings("bool", a.tokenText(a.nodes.items[parameters[2].type_expr].identifier.tok_index));

    const maybe = a.nodes.items[roots[1]].func_lit.signature;
    try std.testing.expectEqual(.uniform, maybe.return_variability.?);
    const optional = a.nodes.items[maybe.return_type.?].optional;
    try std.testing.expectEqualStrings("u8", a.tokenText(a.nodes.items[optional.child].identifier.tok_index));

    const fallible = a.nodes.items[roots[2]].func_lit.signature;
    try std.testing.expectEqual(.varying, fallible.return_variability.?);
    const err_union = a.nodes.items[fallible.return_type.?].err_union;
    try std.testing.expectEqualStrings("u8", a.tokenText(a.nodes.items[err_union.success].identifier.tok_index));
    try std.testing.expectEqualStrings("error", a.tokenText(a.nodes.items[err_union.err].identifier.tok_index));

    const shared = a.nodes.items[roots[3]].func_lit.signature;
    try std.testing.expectEqual(.uniform, shared.return_variability.?);
    try std.testing.expectEqualStrings("u8", a.tokenText(a.nodes.items[shared.return_type.?].identifier.tok_index));
    try std.testing.expectEqual(TokenType.eof, parser.peekToken().type);
}

test "named functions compose with conditionals returns and calls" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(
        "fn choose(x: u8, y: f64) u32 { if (x < y) { return sum(x, y); } else return values[0]; }; " ++
        "fn empty() { return []; }; choose(2 + 3, 4);",
    );
    var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer a.deinit(allocator);
    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();

    try std.testing.expectEqual(@as(u32, 3), a.roots.len);
    const roots = a.extra.items[a.roots.start..][0..a.roots.len];
    const func = a.nodes.items[roots[0]].func_lit;
    try std.testing.expectEqualStrings("choose", a.tokenText(func.signature.name));
    try std.testing.expect(func.signature.return_variability == null);
    try std.testing.expectEqualStrings("u32", a.tokenText(a.nodes.items[func.signature.return_type.?].identifier.tok_index));
    const parameters = func.signature.args.?;
    try std.testing.expectEqual(@as(u32, 2), parameters.len);
    try std.testing.expect(a.parameters.items[parameters.start].variability == null);
    try std.testing.expect(a.parameters.items[parameters.start + 1].variability == null);
    try std.testing.expectEqualStrings("x", a.tokenText(a.parameters.items[parameters.start].name));
    try std.testing.expectEqualStrings("u8", a.tokenText(a.nodes.items[a.parameters.items[parameters.start].type_expr].identifier.tok_index));
    try std.testing.expectEqualStrings("f64", a.tokenText(a.nodes.items[a.parameters.items[parameters.start + 1].type_expr].identifier.tok_index));
    const body = a.nodes.items[func.body].block.statements;
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const conditional = a.nodes.items[a.extra.items[body.start]].if_expr;
    try std.testing.expectEqual(TokenType.lt, a.nodes.items[conditional.condition].infix.operator);
    const consequence = a.nodes.items[conditional.consequence].block.statements;
    try std.testing.expectEqual(@as(u32, 1), consequence.len);
    const returned = a.nodes.items[a.extra.items[consequence.start]].return_expr.expression;
    try std.testing.expectEqual(@as(u32, 2), a.nodes.items[returned].call.arguments.len);
    const alternative = a.nodes.items[conditional.alternative.?].return_expr.expression;
    try std.testing.expectEqual(@as(i64, 0), a.nodes.items[a.nodes.items[alternative].index_expr.idx].integer.value);
    const empty = a.nodes.items[roots[1]].func_lit;
    try std.testing.expectEqualStrings("empty", a.tokenText(empty.signature.name));
    try std.testing.expect(empty.signature.args == null);
    try std.testing.expect(empty.signature.return_type == null);
    try std.testing.expect(empty.signature.return_variability == null);
    try std.testing.expectEqual(@as(u32, 2), a.parameters.items.len);
    try std.testing.expectEqual(@as(u32, 2), a.nodes.items[roots[2]].call.arguments.len);
    try std.testing.expectEqual(TokenType.eof, parser.peekToken().type);
}

test "malformed expressions lists and signatures return errors" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ "[1", ParseError.ExpectedRightBracket },
        .{ "[", ParseError.ExpectedRightBracket },
        .{ "[1 2];", ParseError.ExpectedSeparator },
        .{ "[1,];", ParseError.ExpectedExpression },
        .{ "[1,,2];", ParseError.ExpectedExpression },
        .{ "f(1", ParseError.ExpectedRightParen },
        .{ "f(", ParseError.ExpectedRightParen },
        .{ "f(1 2);", ParseError.ExpectedSeparator },
        .{ "f(1,);", ParseError.ExpectedExpression },
        .{ "f(,1);", ParseError.ExpectedExpression },
        .{ "x[];", ParseError.ExpectedExpression },
        .{ "x[1;", ParseError.ExpectedRightBracket },
        .{ "(1 + 2;", ParseError.ExpectedRightParen },
        .{ "1 + ;", ParseError.ExpectedExpression },
        .{ "fn f() u8 u32 {};", ParseError.ExpectedLeftBrace },
        .{ "fn f() u8 { return 1;", ParseError.ExpectedRightBrace },
        .{ "fn f(uniform) {};", ParseError.ExpectedParameterName },
        .{ "fn f(varying x) {};", ParseError.ExpectedSeparator },
        .{ "fn f(x u8) {};", ParseError.ExpectedSeparator },
        .{ "fn f(uniform x u8) {};", ParseError.ExpectedSeparator },
        .{ "fn f(varying x u8) {};", ParseError.ExpectedSeparator },
        .{ "fn f(x: ) {};", ParseError.ExpectedParameterType },
        .{ "fn f(varying x: ) {};", ParseError.ExpectedParameterType },
        .{ "fn f(x:: u8) {};", ParseError.ExpectedParameterType },
        .{ "fn f(uniform varying x: u8) {};", ParseError.ExpectedParameterName },
        .{ "fn f() uniform {};", ParseError.ExpectedParameterType },
        .{ "fn f() varying", ParseError.ExpectedParameterType },
        .{ "fn f() uniform varying u8 {};", ParseError.ExpectedParameterType },
        .{ "if (x) {} else", ParseError.InvalidCharacter },
        .{ "\"unterminated", ParseError.InvalidCharacter },
        .{ "@;", ParseError.InvalidCharacter },
    };
    inline for (cases) |case| {
        var lexer = Lexer.init(case[0]);
        var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
        defer a.deinit(allocator);
        var parser = try Parser.init(allocator, &a, &lexer);
        try std.testing.expectError(case[1], parser.parse());
    }
}

fn parseAllocationTest(allocator: Allocator) !void {
    var lexer = Lexer.init(
        "fn f(varying x: u32) varying u32 { return g([x, h(2)], values[0]); }; " ++
        "f([1, [2, 3]][0]);",
    );
    var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer a.deinit(allocator);
    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();
}

test "nested parser allocations are cleaned up on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseAllocationTest, .{});
}

test "parameters allow an empty range" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(")");
    var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer a.deinit(allocator);
    var parser = try Parser.init(allocator, &a, &lexer);

    const range = try parseParameters(&parser);
    try std.testing.expectEqual(@as(u32, 0), range.len);
    try std.testing.expectEqual(TokenType.rparen, parser.peekToken().type);
}

test "parse expression" {
    const allocator = std.testing.allocator;
    const source = "2 + 4 * 2;";

    var lexer = Lexer.init(source);

    var a: Ast = .{
        .source = lexer.buffer,
        .roots = .{ .start = 0, .len = 0 },
    };
    defer a.deinit(allocator);

    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();

    try std.testing.expect(1 == parser.ast.roots.len);

    const s = a.roots.start;
    const start = a.extra.items[s];

    const root = a.nodes.items[start].infix;
    const operator = root.operator;
    const op = Token.tokenString(operator);

    const left_node = a.nodes.items[root.left].integer;
    const left_token = left_node.value;

    const right_node = a.nodes.items[root.right].infix;
    const right_token = Token.tokenString(right_node.operator);

    const child_left = a.nodes.items[right_node.left].integer.value;
    const child_right = a.nodes.items[right_node.right].integer.value;

    try std.testing.expectEqualStrings("+", op.?);
    try std.testing.expectEqual(@as(i64, 2), left_token);
    try std.testing.expectEqualStrings("*", right_token.?);
    try std.testing.expectEqual(@as(i64, 4), child_left);
    try std.testing.expectEqual(@as(i64, 2), child_right);
}

test "parse prefix" {
    const allocator = std.testing.allocator;
    const source = "-5;";

    var lexer = Lexer.init(source);

    var a: Ast = .{
        .source = lexer.buffer,
        .roots = .{ .start = 0, .len = 0 },
    };
    defer a.deinit(allocator);

    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();

    try std.testing.expect(1 == parser.ast.roots.len);

    const s = a.roots.start;
    const start = a.extra.items[s];

    const root = a.nodes.items[start].prefix;
    const operator = root.operator;
    const op = Token.tokenString(operator);

    const right = a.nodes.items[root.right].integer.value;

    try std.testing.expectEqualStrings("-", op.?);
    try std.testing.expectEqual(@as(i64, 5), right);

}

test "parse if expression" {
    const allocator = std.testing.allocator;
    const source = "if (2 > 3) return 0; else { return 1; }";

    var lexer = Lexer.init(source);

    var a: Ast = .{
        .source = lexer.buffer,
        .roots = .{ .start = 0, .len = 0 },
    };
    defer a.deinit(allocator);

    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();

    try std.testing.expect(1 == parser.ast.roots.len);

    const s = a.roots.start;
    const start = a.extra.items[s];
    const root = a.nodes.items[start].if_expr;
    const if_alt = root.alternative.?;

    const condition_op = a.nodes.items[root.condition].infix.operator;
    const cond_op = Token.tokenString(condition_op);

    const consequence = a.nodes.items[root.consequence].return_expr;
    const consq = a.nodes.items[consequence.expression].integer.value;

    const alternative = a.nodes.items[if_alt].block;
    const alt_return_idx = a.extra.items[alternative.statements.start];
    const alt_return = a.nodes.items[alt_return_idx].return_expr;
    const alt = a.nodes.items[alt_return.expression].integer.value;

    try std.testing.expectEqual(@as(i64, 0), consq);
    try std.testing.expectEqual(@as(i64, 1), alt);
    try std.testing.expectEqualStrings(">", cond_op.?);
}
