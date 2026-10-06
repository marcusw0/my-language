const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Tokenizer = @import("token.zig");
const Token = @import("token.zig").Token;
const tok_type = @import("token.zig").Type;
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

        while (self.peek_token().type != .eof) {
            const root_idx = try parse_statement(self);
            try root_indices.append(self.allocator, root_idx);
        }
        self.ast.roots = try self.ast.addRange(
            self.allocator,
            root_indices.items,
        );
    }

    fn next_token(self: *Parser) Token {
        self.tok_idx += 1;
        return self.ast.tokens.items[self.tok_idx - 1];
    }

    fn peek_token(self: *Parser) Token {
        return self.ast.tokens.items[self.tok_idx];
    }
};

fn parse_statement(p: *Parser) ParseError!NodeIndex {
    const token = p.peek_token();

    const index = switch (token.type) {
        .key_return => try parse_return(p),
        .key_func => try parse_func(p),
        else => try parse_expression(p, .lowest),
    };

    const nodeType = p.ast.nodes.items[index];
    switch (nodeType) {
        .if_expr => {
            if (p.peek_token().type == .semicolon) {
                return ParseError.InvalidCharacter;
            }
            return index;
        },
        else => {
            if (p.peek_token().type != .semicolon) {
                return ParseError.ExpectedTerminator;
            }
            _ = p.next_token();
            return index;
        }
    }
}

fn parse_expression(p: *Parser, minimum: Precedence) ParseError!NodeIndex {
    const token = p.peek_token();

    var left_idx: NodeIndex = switch (token.type) {
        .int => try parse_integer_lit(p, token),

        .ident => blk: {
            const index = @as(u32, @intCast(p.tok_idx));
            _ = p.next_token();
            break :blk try p.ast.addNode(p.allocator, .{
                .identifier = .{ .tok_index = index },
            });
        },

        .string_lit => blk: {
            const index = @as(u32, @intCast(p.tok_idx));
            _ = p.next_token();
            break :blk try p.ast.addNode(p.allocator, .{
                .string_lit = .{ .tok_index = index },
            });
        },

        .lbracket => try parse_array_lit(p),

        .lparen => blk: {
            _ = p.next_token(); // Consume '('.
            const inner_idx = try parse_expression(p, .lowest);

            if (p.peek_token().type != .rparen)
                return error.ExpectedRightParen;

            _ = p.next_token(); // Consume ')'.
            break :blk inner_idx;
        },

        .minus, .bang, .plus => try parse_prefix(p, token),

        .key_if => try parse_if(p),

        .illegal => return ParseError.InvalidCharacter,

        else => return error.ExpectedExpression,
    };

    while (@intFromEnum(precedence(p.peek_token())) >
        @intFromEnum(minimum)) {
        left_idx = switch (p.peek_token().type) {
            .lparen => try parse_call(p, left_idx),
            .lbracket => try parse_index(p, left_idx),
            else => try parse_infix(p, left_idx),
        };
    }
    return left_idx;
}

fn parse_func(p: *Parser) ParseError!NodeIndex {
    _ = p.next_token();

    if (p.peek_token().type != .ident) {
        return ParseError.InvalidCharacter;
    }
    const name = @as(u32, @intCast(p.tok_idx));
    _ = p.next_token();

    if (p.peek_token().type != .lparen) {
        return ParseError.ExpectedLeftParen;
    }
    _ = p.next_token();

    var args: ?ast.ParameterRange = null;
    if (p.peek_token().type != .rparen) {
        args = try parse_parameters(p);
    }
    if (p.peek_token().type != .rparen) return ParseError.ExpectedRightParen;
    _ = p.next_token();

    var signature = ast.FuncSignature{
        .name = name,
        .args = args,
        .return_type = null,
    };

    if (p.peek_token().type == .ident) {
        signature.return_type = @as(u32, @intCast(p.tok_idx));
        _ = p.next_token();
    }

    if (p.peek_token().type != .lbrace) {
        return ParseError.ExpectedLeftBrace;
    }

    const body = try parse_block(p);

    return try p.ast.addNode(p.allocator, .{
        .func_lit = .{
            .body = body,
            .signature = signature,
        }
    });
}

fn parse_parameters(p: *Parser) ParseError!ast.ParameterRange {
    const start = p.ast.parameters.items.len;
    errdefer p.ast.parameters.items.len = start;

    if (p.peek_token().type != .rparen) {
        while (true) {
            if (p.peek_token().type != .ident) return ParseError.ExpectedParameterName;
            const name = @as(u32, @intCast(p.tok_idx));
            _ = p.next_token();

            if (p.peek_token().type != .ident) return ParseError.ExpectedParameterType;
            const type_expr = @as(u32, @intCast(p.tok_idx));
            _ = p.next_token();

            try p.ast.parameters.append(p.allocator, .{
                .name = name,
                .type_expr = type_expr,
            });

            if (p.peek_token().type == .rparen) break;
            if (p.peek_token().type == .eof) return ParseError.ExpectedRightParen;
            if (p.peek_token().type != .comma) return ParseError.ExpectedSeparator;
            _ = p.next_token();
        }
    }

    return .{
        .start = @intCast(start),
        .len = @intCast(p.ast.parameters.items.len - start),
    };
}

fn parse_if(p: *Parser) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.next_token();
    if (p.peek_token().type != .lparen) return ParseError.ExpectedLeftParen;

    const condition = try parse_expression(p, .lowest);

    if (p.peek_token().type != .lbrace and p.peek_token().type != .key_return) {
        return ParseError.InvalidCharacter;
    }

    const consequence = try parse_block(p);

    var alternative: ?NodeIndex = null;
    if (p.peek_token().type == .key_else) {
        _ = p.next_token();

        if (p.peek_token().type != .lbrace and p.peek_token().type != .key_return) {
            return ParseError.InvalidCharacter;
        }
        alternative = try parse_block(p);

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

fn parse_block(p: *Parser) ParseError!NodeIndex {
    if (p.peek_token().type == .key_return) {
        return try parse_statement(p);
    }
    if (p.peek_token().type != .lbrace) return ParseError.ExpectedLeftBrace;
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.next_token();

    var node_indices: std.ArrayList(NodeIndex) = .empty;
    defer node_indices.deinit(p.allocator);

    while (p.peek_token().type != .rbrace and p.peek_token().type != .eof) {
        const node_idx = try parse_statement(p);
        try node_indices.append(p.allocator, node_idx);
    }

    if (p.peek_token().type != .rbrace) return ParseError.ExpectedRightBrace;
    _ = p.next_token();

    const range = try p.ast.addRange(p.allocator, node_indices.items);

    return try p.ast.addNode(p.allocator, .{
        .block = .{
            .tok_index = index,
            .statements = range,
        }
    });
}

fn parse_return(p: *Parser) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.next_token();
    const expression = try parse_expression(p, .lowest);

    return p.ast.addNode(p.allocator, .{
        .return_expr = .{
            .tok_index = index,
            .expression = expression,
        }
    });
}

fn parse_prefix(p: *Parser, token: Token) ParseError!NodeIndex {
    _ = p.next_token();
    const right = try parse_expression(p, .prefix);
    return try p.ast.addNode(p.allocator, .{
        .prefix = .{
            .operator = token.type,
            .right = right,
        }
    });
}

fn parse_expression_list(p: *Parser, closing: tok_type) ParseError!ast.NodeRange {
    var indices: std.ArrayList(NodeIndex) = .empty;
    defer indices.deinit(p.allocator);

    const expected_closing: ParseError = switch (closing) {
        .rparen => ParseError.ExpectedRightParen,
        .rbracket => ParseError.ExpectedRightBracket,
        else => unreachable,
    };

    if (p.peek_token().type != closing) {
        while (true) {
            if (p.peek_token().type == .eof) return expected_closing;
            const index = try parse_expression(p, .lowest);
            try indices.append(p.allocator, index);

            if (p.peek_token().type == closing) break;
            if (p.peek_token().type == .eof) return expected_closing;
            if (p.peek_token().type != .comma) return ParseError.ExpectedSeparator;
            _ = p.next_token();
            // As with parameter lists, a trailing comma is not accepted.
            if (p.peek_token().type == closing) return ParseError.ExpectedExpression;
        }
    }
    _ = p.next_token();
    return try p.ast.addRange(p.allocator, indices.items);
}

fn parse_array_lit(p: *Parser) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.next_token(); // Consume '['.
    const elements = try parse_expression_list(p, .rbracket);
    return try p.ast.addNode(p.allocator, .{
        .array_lit = .{ .tok_index = index, .elements = elements },
    });
}

fn parse_call(p: *Parser, func: NodeIndex) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.next_token(); // Consume '('.
    const arguments = try parse_expression_list(p, .rparen);
    return try p.ast.addNode(p.allocator, .{
        .call = .{ .tok_index = index, .func = func, .arguments = arguments },
    });
}

fn parse_index(p: *Parser, left: NodeIndex) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.next_token(); // Consume '['.
    const idx = try parse_expression(p, .lowest);
    if (p.peek_token().type != .rbracket) return ParseError.ExpectedRightBracket;
    _ = p.next_token(); // Consume ']'.
    return try p.ast.addNode(p.allocator, .{
        .index_expr = .{ .tok_index = index, .left = left, .idx = idx },
    });
}

fn parse_infix(p: *Parser, left_idx: NodeIndex) ParseError!NodeIndex {
    const operator = p.peek_token();
    const op_type = operator.type;
    const operator_precedence = precedence(operator);

    _ = p.next_token(); // Consume the operator.

    const right_idx = try parse_expression(p, operator_precedence);

    return try p.ast.addNode(p.allocator, .{
        .infix = .{
            .left = left_idx,
            .operator = op_type,
            .right = right_idx,
        },
    });
}

fn parse_integer_lit(p: *Parser, token: Token) !NodeIndex {
    const buffer: []const u8 = p.ast.source[token.byte_start..token.byte_end];
    const value = try std.fmt.parseInt(i64, buffer, 0);
    const node: Node = .{ .integer = .{ .value = value } };
    const node_idx = try p.ast.addNode(p.allocator, node);
    _ = p.next_token();
    return node_idx;
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
    try std.testing.expectEqual(tok_type.plus, sum.operator);
    try std.testing.expectEqual(@as(i64, 2), a.nodes.items[sum.left].integer.value);
    try std.testing.expectEqual(@as(i64, 3), a.nodes.items[sum.right].integer.value);
    const nested = a.nodes.items[elements[2]].array_lit.elements;
    try std.testing.expectEqual(@as(u32, 1), nested.len);
    try std.testing.expectEqual(@as(i64, 4), a.nodes.items[a.extra.items[nested.start]].integer.value);
    try std.testing.expectEqual(tok_type.eof, parser.peek_token().type);
}

test "named functions compose with conditionals returns and calls" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(
        "fn choose(x u8, y f64) u32 { if (x < y) { return sum(x, y); } else return values[0]; }; " ++
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
    try std.testing.expectEqualStrings("u32", a.tokenText(func.signature.return_type.?));
    const parameters = func.signature.args.?;
    try std.testing.expectEqual(@as(u32, 2), parameters.len);
    try std.testing.expectEqualStrings("x", a.tokenText(a.parameters.items[parameters.start].name));
    try std.testing.expectEqualStrings("u8", a.tokenText(a.parameters.items[parameters.start].type_expr));
    try std.testing.expectEqualStrings("f64", a.tokenText(a.parameters.items[parameters.start + 1].type_expr));
    const body = a.nodes.items[func.body].block.statements;
    try std.testing.expectEqual(@as(u32, 1), body.len);
    const conditional = a.nodes.items[a.extra.items[body.start]].if_expr;
    try std.testing.expectEqual(tok_type.lt, a.nodes.items[conditional.condition].infix.operator);
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
    try std.testing.expectEqual(@as(u32, 2), a.parameters.items.len);
    try std.testing.expectEqual(@as(u32, 2), a.nodes.items[roots[2]].call.arguments.len);
    try std.testing.expectEqual(tok_type.eof, parser.peek_token().type);
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

fn parse_allocation_test(allocator: Allocator) !void {
    var lexer = Lexer.init(
        "fn f(x u32) u32 { return g([x, h(2)], values[0]); }; " ++
        "f([1, [2, 3]][0]);",
    );
    var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer a.deinit(allocator);
    var parser = try Parser.init(allocator, &a, &lexer);
    try parser.parse();
}

test "nested parser allocations are cleaned up on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parse_allocation_test, .{});
}

test "parameters allow an empty range" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(")");
    var a: Ast = .{ .source = lexer.buffer, .roots = .{ .start = 0, .len = 0 } };
    defer a.deinit(allocator);
    var parser = try Parser.init(allocator, &a, &lexer);

    const range = try parse_parameters(&parser);
    try std.testing.expectEqual(@as(u32, 0), range.len);
    try std.testing.expectEqual(tok_type.rparen, parser.peek_token().type);
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
    const op = Token.token_string(operator);

    const leftNode = a.nodes.items[root.left].integer;
    const leftToken = leftNode.value;

    const rightNode = a.nodes.items[root.right].infix;
    const rightToken = Token.token_string(rightNode.operator);

    const childLeft = a.nodes.items[rightNode.left].integer.value;
    const childRight = a.nodes.items[rightNode.right].integer.value;

    try std.testing.expectEqualStrings("+", op.?);
    try std.testing.expectEqual(@as(i64, 2), leftToken);
    try std.testing.expectEqualStrings("*", rightToken.?);
    try std.testing.expectEqual(@as(i64, 4), childLeft);
    try std.testing.expectEqual(@as(i64, 2), childRight);
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
    const op = Token.token_string(operator);

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
    const cond_op = Token.token_string(condition_op);

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
