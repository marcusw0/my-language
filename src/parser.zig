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
    ExpectedRightBrace,
    ExpectedSeparator,
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

        else => return error.ExpectedExpression,
    };

    while (@intFromEnum(precedence(p.peek_token())) >
        @intFromEnum(minimum)) {
        left_idx = try parse_infix(p, left_idx);
    }
    return left_idx;
}

fn parse_func(p: *Parser) ParseError!NodeIndex {
    const index = @as(u32, @intCast(p.tok_idx));
    _ = p.next_token();

    if (p.peek_token().type != .ident) {
        return ParseError.InvalidCharacter;
    }
    _ = p.next_token();

    if (p.peek_token().type != .lparen) {
        return ParseError.ExpectedLeftParen;
    }
    _ = p.next_token();

    var parameters: ?ast.NodeRange = null;
    if (p.peek_token().type != .rparen) {
        parameters = try parse_parameters(p);
    }
    _ = p.next_token();

    if (p.peek_token().type != .lbrace) {
        return ParseError.ExpectedLeftBrace;
    }

    const body = try parse_block(p);

    return try p.ast.addNode(p.allocator, .{
        .func_lit = .{
            .tok_index = index,
            .parameters = parameters,
            .return_type = null,
            .body = body,
        }
    });
}

fn parse_parameters(p: *Parser) ParseError!ast.NodeRange {
    var param_indices: std.ArrayList(NodeIndex) = .empty;
    defer param_indices.deinit(p.allocator);

    while (p.peek_token().type != .rparen) {
        const tokenType = p.peek_token().type;
        if (tokenType != .comma) {
            const tok_idx = @as(u32, @intCast(p.tok_idx));
            const param = try p.ast.addNode(p.allocator, .{ .parameter = .{
                .name = tok_idx,
                .type_expr = tokenType,
            } });

            try param_indices.append(p.allocator, param);
            _ = p.next_token();
            _ = p.next_token();
        }
    }
    _ = p.next_token();

    return try p.ast.addRange(p.allocator, param_indices.items);
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
    const right = try parse_expression(p, .lowest);
    return try p.ast.addNode(p.allocator, .{
        .prefix = .{
            .operator = token.type,
            .right = right,
        }
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
    const node: Node = .{ .integer = .{ .value = value, .tok_index = @as(u32, @intCast(p.tok_idx)) } };
    const node_idx = try p.ast.addNode(p.allocator, node);
    _ = p.next_token();
    return node_idx;
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
