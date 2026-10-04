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
    ExpectedRightParen,
    ExpectedSeparator,
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
            const root_idx = try parse_expression(self, .lowest);
            try root_indices.append(self.allocator, root_idx);

            switch (self.peek_token().type) {
                .semicolon => {
                    _ = self.next_token();
                },
                .eof => {},
                else => return error.ExpectedSeparator,
            }
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

        else => return error.ExpectedExpression,
    };

    while (@intFromEnum(precedence(p.peek_token())) >
        @intFromEnum(minimum))
    {
        left_idx = try parse_infix(p, left_idx);
    }

    return left_idx;
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
    const source = "2 + 4 * 2";

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
    const source = "-5";

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
