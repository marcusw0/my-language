const std = @import("std");
const token = @import("token.zig");

const TokenIndex = u32;
const NodeIndex = u32;

pub const Node = union(enum) {
    type_name: TypeName,
    identifier: Identifier,
    integer: IntegerLiteral,
    string_lit: StringLiteral,
    array_lit: ArrayLiteral,
    infix: InfixExpression,
    index_expr: IndexExpression,
    prefix: Prefix,
    func_lit: FunctionLiteral,
    call: Call,
    block: Block,
    return_expr: Return,
    if_expr: If,
};

pub const TypeName = struct {
    tok_index: TokenIndex,
};

pub const Identifier = struct {
    tok_index: TokenIndex,
};

pub const IntegerLiteral = struct {
    value: i64,
};

pub const StringLiteral = struct {
    tok_index: TokenIndex,
};

pub const ArrayLiteral = struct {
    elements: NodeRange,
    tok_index: TokenIndex,
};

pub const InfixExpression = struct {
    operator: token.Type,
    left: NodeIndex,
    right: NodeIndex,
};

pub const IndexExpression = struct {
    tok_index: TokenIndex,
    left: NodeIndex,
    idx: NodeIndex,
};

pub const Prefix = struct {
    operator: token.Type,
    right: NodeIndex,
};

pub const FuncSignature = struct {
    args: ?ParameterRange,
    name: TokenIndex,
    return_type: ?TokenIndex,
};

pub const FunctionLiteral = struct {
    signature: FuncSignature,
    body: NodeIndex, // Block node
};

pub const Call = struct {
    arguments: NodeRange, // Expression-node indices in Ast.extra
    tok_index: TokenIndex, // The "(" token
    func: NodeIndex,
};

pub const Parameter = struct {
    type_expr: TokenIndex,
    name: TokenIndex,
};

pub const Block = struct {
    statements: NodeRange,
    tok_index: TokenIndex, // The "{" token
};

pub const Return = struct {
    tok_index: TokenIndex,
    expression: NodeIndex,
};

pub const If = struct {
    tok_index: TokenIndex, // The "if" token
    condition: NodeIndex,
    consequence: NodeIndex,
    alternative: ?NodeIndex,
};

pub const NodeRange = struct {
    start: u32,
    len: u32,
};

pub const ParameterRange = struct {
    start: u32,
    len: u32,
};

pub const Ast = struct {
    tokens: std.ArrayList(token.Token) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    extra: std.ArrayList(NodeIndex) = .empty,
    parameters: std.ArrayList(Parameter) = .empty,
    roots: NodeRange,
    source: []const u8,

    pub fn addNode(self: *Ast, allocator: std.mem.Allocator, node: Node) !NodeIndex {
        const index: NodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        return index;
    }

    pub fn addRange(self: *Ast, allocator: std.mem.Allocator, children: []const NodeIndex) !NodeRange {
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(allocator, children);
        return NodeRange{ .start = start, .len = @intCast(children.len)};
    }

    pub fn tokenText(self: *const Ast, index: TokenIndex) []const u8 {
        const tok = self.tokens.items[index];
        return self.source[tok.byte_start..tok.byte_end];
    }

    pub fn deinit(self: *Ast, allocator: std.mem.Allocator) void {
        self.tokens.deinit(allocator);
        self.nodes.deinit(allocator);
        self.extra.deinit(allocator);
        self.parameters.deinit(allocator);
        self.* = undefined;
    }
};

test "infix node references its operands and operator" {
    const allocator = std.testing.allocator;
    const source = "2 + 3";

    var ast: Ast = .{
        .source = source,
        .roots = .{ .start = 0, .len = 0 },
    };
    defer ast.deinit(allocator);

    var lexer = token.Lexer.init(source);
    while (true) {
        const tok = lexer.nextToken();
        try ast.tokens.append(allocator, tok);
        if (tok.type == .eof) break;
    }

    const left = try ast.addNode(allocator, .{
        .integer = .{ .value = 2 },
    });
    const right = try ast.addNode(allocator, .{
        .integer = .{ .value = 3 },
    });
    const expression = try ast.addNode(allocator, .{
         .infix = .{ .left = left, .operator = token.Type.plus, .right = right },
    });

    ast.roots = try ast.addRange(allocator, &.{expression});

    const root_idx = ast.extra.items[ast.roots.start];
    const infix = ast.nodes.items[root_idx].infix;
    const infix_op = token.Token.token_string(infix.operator);

    try std.testing.expectEqual(@as(u32, 1), ast.roots.len);
    try std.testing.expectEqual(
       @as(i64, 2),
       ast.nodes.items[infix.left].integer.value,
    );
    try std.testing.expectEqual(
       @as(i64, 3),
       ast.nodes.items[infix.right].integer.value,
    );
    try std.testing.expectEqualStrings("+", infix_op.?);
}

test "AST node layout" {
    std.debug.print("\n{s:<24} {s:>10} {s:>10}\n", .{ "Type", "Size (B)", "Align (B)" });

    inline for (.{
        Node, TypeName, Identifier, IntegerLiteral, StringLiteral,
        ArrayLiteral, InfixExpression, IndexExpression, Prefix,
        FunctionLiteral, Call, Parameter, Block, If, FuncSignature,
    }) |T| {
        std.debug.print("{s:<24} {d:>10} {d:>10}\n", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
    }
}
