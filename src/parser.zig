const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Token = @import("token.zig").Token;
const tok_type = @import("token.zig").Type;
const Lexer = @import("token.zig").Lexer;
const ast = @import("ast.zig");
const Ast = ast.Ast;
const Node = ast.Node;

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
    const p = Precedence;
    switch (token.type) {
        .eq, .not_eq => p.equals,
        .lt, .gt => p.lessgreater,
        .plus, .minus => p.sum,
        .asterisk, .slash => p.product,
        .lparen => p.call,
        .lbracket => p.index,
        else => p.lowest,
    }
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
        while (self.peek_token().type != tok_type.eof) {
            try parse_program(self);
        }
    }

    fn next_token(self: *Parser) Token {
        self.tok_idx += 1;
        return self.ast.tokens.items[self.tok_idx - 1];
    }

    fn peek_token(self: *Parser) Token {
        return self.ast.tokens.items[self.tok_idx];
    }
};

fn parse_program(p: *Parser) !void {
    _ = p;
}

fn parse_integer_lit(p: *Parser) void {
    _ = p;
}
