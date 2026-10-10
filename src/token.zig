const std = @import("std");

pub const Type = enum {
    illegal,
    eof,
    ident,
    int,
    string_lit,
    assign,
    bang,
    question,
    slash,
    eq,
    not_eq,
    lt,
    gt,
    plus,
    minus,
    asterisk,
    comma,
    semicolon,
    colon,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    key_orelse,
    key_func,
    key_if,
    key_else,
    key_return,
    key_uniform,
    key_varying,
};

pub const keywords = std.StaticStringMap(Type).initComptime(.{
    .{ "orelse", .key_orelse },
    .{ "fn", .key_func },
    .{ "if", .key_if },
    .{ "else", .key_else },
    .{ "return", .key_return },
    .{ "uniform", .key_uniform },
    .{ "varying", .key_varying },
});


pub const Token = struct {
    type: Type,
    byte_start: usize,
    byte_end: usize,

    pub fn lookupIdent(ident: []const u8) Type {
        return keywords.get(ident) orelse .ident;
    }

    pub fn token_string(tag: Type) ?[]const u8 {
        return switch (tag) {
            .illegal,
            .eof,
            .ident,
            .int,
            .string_lit,
            => null,

            .assign => "=",
            .plus => "+",
            .minus => "-",
            .bang => "!",
            .question => "?",
            .asterisk => "*",
            .slash => "/",
            .lt => "<",
            .gt => ">",
            .eq => "==",
            .not_eq => "!=",
            .comma => ",",
            .semicolon => ";",
            .colon => ":",
            .lparen => "(",
            .rparen => ")",
            .lbrace => "{",
            .rbrace => "}",
            .lbracket => "[",
            .rbracket => "]",
            .key_orelse => "orelse",
            .key_func => "fn",
            .key_if => "if",
            .key_else => "else",
            .key_return => "return",
            .key_uniform => "uniform",
            .key_varying => "varying",
        };
    }
};

pub const Lexer = struct {
    buffer: [:0]const u8,
    index: usize,

    pub fn init(buffer: [:0]const u8) Lexer {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }

    pub fn nextToken(self: *Lexer) Token {
        var tok: Token = .{
            .type = undefined,
            .byte_start = self.index,
            .byte_end = undefined,
        };

        state: switch (enum { start, ident, int, equal, string_lit }.start) {
            .start => {
                if (self.index == self.buffer.len) {
                    return .{
                        .type = .eof,
                        .byte_start = self.index,
                        .byte_end = self.index
                    };
                }

                switch (self.buffer[self.index]) {
                    ' ', '\t', '\n', '\r' => {
                        self.index += 1;
                        tok.byte_start = self.index;
                        continue :state .start;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        tok.type = .ident;
                        continue :state .ident;
                    },
                    '0'...'9' => {
                        tok.type = .int;
                        continue :state .int;
                    },
                    '=' => continue :state .equal,
                    '+' => {
                        tok.type = .plus;
                        self.index += 1;
                    },
                    '-' => {
                        tok.type = .minus;
                        self.index += 1;
                    },
                    '!' => {
                        self.index += 1;
                        if (self.buffer[self.index] == '=') {
                            tok.type = .not_eq;
                            self.index += 1;
                        } else { tok.type = .bang; }
                    },
                    '?' => {
                        tok.type = .question;
                        self.index += 1;
                    },
                    '/' => {
                        tok.type = .slash;
                        self.index += 1;
                    },
                    '*' => {
                        tok.type = .asterisk;
                        self.index += 1;
                    },
                    '<' => {
                        tok.type = .lt;
                        self.index += 1;
                    },
                    '>' => {
                        tok.type = .gt;
                        self.index += 1;
                    },
                    ';' => {
                        tok.type = .semicolon;
                        self.index += 1;
                    },
                    ':' => {
                        tok.type = .colon;
                        self.index += 1;
                    },
                    '(' => {
                        tok.type = .lparen;
                        self.index += 1;
                    },
                    ')' => {
                        tok.type = .rparen;
                        self.index += 1;
                    },
                    '{' => {
                        tok.type = .lbrace;
                        self.index += 1;
                    },
                    '}' => {
                        tok.type = .rbrace;
                        self.index += 1;
                    },
                    '[' => {
                        tok.type = .lbracket;
                        self.index += 1;
                    },
                    ']' => {
                        tok.type = .rbracket;
                        self.index += 1;
                    },
                    ',' => {
                        tok.type = .comma;
                        self.index += 1;
                    },
                    '"' => {
                        self.index += 1;
                        continue :state .string_lit;
                    },
                    else => {
                        tok.type = .illegal;
                        self.index += 1;
                    },
                }
            },

            .ident => {
                if (self.index < self.buffer.len) {
                    switch (self.buffer[self.index]) {
                        'a'...'z', 'A'...'Z', '0'...'9', '_' => {
                            self.index += 1;
                            continue :state .ident;
                        },
                        else => {},
                    }
                }

                tok.type = Token.lookupIdent(self.buffer[tok.byte_start..self.index]);
            },

            .int => {
                if (self.index < self.buffer.len) {
                    switch (self.buffer[self.index]) {
                        '0'...'9' => {
                            self.index += 1;
                            continue :state .int;
                        },
                        else => {},
                    }
                }
            },

            .equal => {
                self.index += 1;
                if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
                    self.index += 1;
                    tok.type = .eq;
                } else {
                    tok.type = .assign;
                }
            },

            .string_lit => {
                if (self.index == self.buffer.len) {
                    tok.type = .illegal;
                } else switch (self.buffer[self.index]) {
                    '"' => {
                        tok.type = .string_lit;
                        self.index += 1;
                    },
                    else => {
                        self.index += 1;
                        continue :state .string_lit;
                    }

                }
            },
        }
        tok.byte_end = self.index;
        return tok;
    }

};

test "lexing typed assignment" {
    const source = "a: string = \"hello\";";
    var lexer = Lexer.init(source);

    const expected = [_]Type{
        .ident,
        .colon,
        .ident,
        .assign,
        .string_lit,
        .semicolon,
        .eof,
    };

    for (expected) |kind| {
        const token = lexer.nextToken();
        try std.testing.expectEqual(kind, token.type);
    }
}

test "string literal includes both quotes" {
    const source = " \"hello\"";
    var lexer = Lexer.init(source);

    const token = lexer.nextToken();

    try std.testing.expectEqual(Type.string_lit, token.type);
    try std.testing.expectEqualStrings(
        "\"hello\"",
        source[token.byte_start..token.byte_end],
    );
}

test "unterminated string is illegal" {
    var lexer = Lexer.init("\"hello");

    try std.testing.expectEqual(Type.illegal, lexer.nextToken().type);
    try std.testing.expectEqual(Type.eof, lexer.nextToken().type);
}

test "new lines" {
    var lexer = Lexer.init("\n\t=\r\n");

    try std.testing.expectEqual(Type.assign, lexer.nextToken().type);
    try std.testing.expectEqual(Type.eof, lexer.nextToken().type);
}

test "equal variants" {
    const source =
        \\=
        \\==
        \\!=
        ;
    var lexer = Lexer.init(source);

    const expected = [_]Type{
        .assign,
        .eq,
        .not_eq,
        .eof
    };

    for (expected) |kind| {
        const token = lexer.nextToken();
        try std.testing.expectEqual(kind, token.type);
    }
}
