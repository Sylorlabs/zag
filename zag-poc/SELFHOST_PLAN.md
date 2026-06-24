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
- [x] B2. `ast.zag` — tagged-union Node (19 variants) over *Node; child lists as
       ArrayList[*Node], params ArrayList[Param], enum members ArrayList[[]u8];
       struct/enum/union decls + struct-lit; constructor helpers.
- [x] B3. `parse.zag` — recursive descent: fn/extern, struct/enum/union decls,
       params, types (* ? [] named), blocks, let/return/if/else-if/while/assign/expr,
       full precedence expr chain, struct literals, postfix call/index/field/deref.
       Verified via selfhost/parse_test.zag: fib precedence, enum/struct/union, struct
       literal, and `p.*.x` deref chain all dump to the expected AST.
       Enabling fixes: generic arg + fn-name mangling sanitize illegal C chars;
       instantiated generics emitted before user structs; isPointer matches `*[]u8`.
       (Not yet: @import, generic struct-lit `Foo[T]{}`, slicing/cast/try/catch/orelse
        in expressions, switch — add when sema/codegen need them.)
- [~] B4. `types.zag` — folded into sema for now (effect/builtin tables live in sema.zag).
- [~] B5. `sema.zag` — EFFECT/CAPABILITY CHECKER done (Zag's killer feature, self-hosted):
       fixpoint call-graph effect analysis (effects as i32 bitmask Alloc/Panic/IO/Lock,
       OR via `a+b-(a&b)` since `|` is the capture delimiter), extern effect declarations,
       transitive propagation, and @realtime/@noalloc/@pure/@total constraint verification.
       Verified by selfhost/sema_test.zag: proven-safe fns, direct Alloc violation,
       TRANSITIVE IO violation (rt_io→uses_io→print_i32), intrinsic Panic (division).
       Still TODO for full sema: type inference/checking (currently effect-only), generics
       monomorphization, store checks. The effect system is the differentiator and is done.
- [ ] B6. `codegen.zag`— C backend
- [ ] B7. `main.zag`  — CLI driver (read file, pipeline, invoke cc)

Notes for later stages:
- map.zag must be imported `as map` (its make/get collide with list.zag's); the alias
  propagates through flat re-imports. list.zag is imported flat for ArrayList.
- `|` (bitwise OR) is unusable as a binary op (lexes as capture pipe); use arithmetic.

## Stage C — Bootstrap verification

- [ ] C1. zig-zagc compiles zag-zagc → `zagc2`
- [ ] C2. `zagc2` compiles the full test suite with identical output
- [ ] C3. `zagc2` compiles itself → `zagc3`; `diff` zagc2-output vs zagc3-output (fixpoint)

## Status log

- 2026-06-23: Plan created. Foundation gaps catalogued. Starting Stage A.
