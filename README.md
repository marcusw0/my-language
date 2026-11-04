## My language

An unnamed systems language and compiler written in Zig, with a long-term focus on vector/data-parallel programming while keeping scalar execution valid.

The compiler currently lexes, parses, and performs semantic analysis for a growing subset of the language, including functions, variables, arrays, indexing, operators, conditionals, and named calls. Syntax and semantics are still evolving; code generation and program execution are not implemented yet.

Build and check a source file from this directory:

```sh
zig build
./zig-out/bin/my_language <file>
```
