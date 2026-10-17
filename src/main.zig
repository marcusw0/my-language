const std = @import("std");
const Lexer = @import("token.zig").Lexer;
const Ast = @import("ast.zig").Ast;
const NodeRange = @import("ast.zig").NodeRange;
const Parser = @import("parser.zig").Parser;
const Analyzer = @import("semantics.zig").Analyzer;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 2) {
        std.debug.print("Usage: {s} <filename>\n", .{args[0]});
        return;
    }

    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        init.io,
        args[1],
        init.gpa,
        .limited(10 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer init.gpa.free(source);

    var lexer = Lexer.init(source);
    const range = NodeRange{ .start = 0, .len = 0 };

    var ast = Ast{
        .source = lexer.buffer,
        .roots = range,
    };
    defer ast.deinit(init.gpa);

    var parser = try Parser.init(init.gpa, &ast, &lexer);
    try parser.parse();

    var analyzer = try Analyzer.init(init.gpa, &ast);
    defer analyzer.deinit();
    try analyzer.analyze();
    // while (true) {
    //     const token = lexer.nextToken();
    //     if (token.type == .eof) break;
    //
    //     std.debug.print("{s}: {s}\n", .{
    //         @tagName(token.type),
    //         source[token.byte_start..token.byte_end],
    //     });
    // }
}
