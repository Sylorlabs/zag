# Zag Self-Hosting Plan

Goal: rewrite the Zag compiler (currently ~8000 lines of Zig in `src/`) in Zag itself.
No stubs. Every layer must actually compile and run before moving on.

## Reality check (2026-06-23)

The stdlib written by agents (`std/*.zag`) does **not** compile. It uses a dialect that
doesn't match the implemented language. Verified gaps against the real Zig compiler:

- Pointer indexing `ptr[i]` — sema errors "cannot index non-slice"
- Explicit generic instantiation `foo[T](x)` — unsupported; only inference from value args
- `@sizeOf[T]()` — not a builtin
- `as` casts (`x as *T`, `null as *T`) — unsupported
- extern effect decls (`@alloc @panic`) — `@alloc` lexes as ident, not annotation
- `runtime.c` is never linked → undefined symbols
- Statements require `;`; stdlib has none

What already works: structs/methods, tagged unions, generics (by inference), optionals,
error unions, `@import`, `[]u8` strings, `*T` pointers, `new`/`delete`/`ptr.*`,
effect/capability system, `@intCast`/`@floatCast`/`@truncate`/`@len`/`@strEq`/`@strLen`.

## Stage A — Make the foundation real (Zig compiler work) ✅ DONE

- [x] A1. Pointer indexing `ptr[i]` (sema typeOf + codegen pointer-vs-slice branch)
- [x] A2. `@sizeOf[T]()` builtin (parse type-arg via Call.targs, sema→i32, codegen→`(int32_t)sizeof(CTYPE)`)
- [x] A3. `expr as Type` cast — new Cast node (parse/sema/codegen/clone/effects); subsumes `null as *T`
- [x] A4. Explicit generic instantiation `foo[T1,T2](args)` + module-qualified `mod.foo[T](args)`
       (Call.targs, matchingBracket disambiguation, cloneExpr targs preservation in BOTH clone paths)
- [x] A5. extern effect declarations: `@alloc/@io/@lock/@panic` lexed as annots, added as latent effects
- [x] A6. Link `std/runtime.c` (parser collects runtime.c next to imported modules; main.zig cc argv)
- [x] Bonus: address-of `&expr`→`*T`; resolveType handles `*`/`?`/`!` prefixes;
       intra-module call qualification (var refs renamed, shadowing-safe); opt-typedef
       ordering fix (scan s.fns instantiations before emitting typedefs); extern fns keep
       literal FFI names through qualification.
- [x] A8. Real stdlib: std/rt.zag (FFI), std/list.zag (ArrayList[T]), std/map.zag (StringMap[V]).
       Tests in tests/stdlib/{list,map,io}.zag, runner tests/run_stdlib.sh — all pass with real output.
- [x] A9. All 40 core tests + 3 stdlib tests pass.

Deferred (add when the self-hosted compiler needs them): slice literal `[]T{.ptr=,.len=}`,
arena allocator in zagc itself (currently leaks parse allocations — cosmetic).

## Stage B — Self-hosted compiler (Zag source in `selfhost/`)

Build bottom-up, each module compiled by zig-zagc and tested against the Zig version's behavior.

Enabling language features added for self-hosting (all in the bootstrap compiler):
- char literals `'a'` → integer
- slicing `s[lo..hi]` (Slice node) for slices and pointers
- `else if` chaining (no more `else { if }`)
- fixed lexer bug: `&&`/`||` now tokenize correctly (was split into `&`+`&`)

- [x] B1. `lex.zag` — tokenizer in Zag. 38 token kinds, keywords, annotations,
       two-char ops, char/string/number scanning, comments. Test: selfhost/lex_test.zag
       verifies 30-token kind sequence + slice-extracted token texts. tests/run_selfhost.sh.
- [ ] B2. `ast.zag`   — node tags + constructors (tagged unions over *Node)
- [ ] B3. `parse.zag` — recursive descent; verify AST shape
- [ ] B4. `types.zag` — type helpers, builtin table
- [ ] B5. `sema.zag`  — type checker + effect system
- [ ] B6. `codegen.zag`— C backend
- [ ] B7. `main.zag`  — CLI driver (read file, pipeline, invoke cc)

## Stage C — Bootstrap verification

- [ ] C1. zig-zagc compiles zag-zagc → `zagc2`
- [ ] C2. `zagc2` compiles the full test suite with identical output
- [ ] C3. `zagc2` compiles itself → `zagc3`; `diff` zagc2-output vs zagc3-output (fixpoint)

## Status log

- 2026-06-23: Plan created. Foundation gaps catalogued. Starting Stage A.
