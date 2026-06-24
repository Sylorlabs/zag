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
- [x] B6. `codegen.zag` — C backend in Zag: emits into ArrayList[u8], ctype mapping,
       prelude + prototypes (incl extern) + bodies, exprs/stmts. Verified end-to-end:
       codegens fib(10), the C compiles with cc and prints 55.
- [x] B7. `zagc.zag` — the self-hosted compiler DRIVER (CLI). Reads argv (via runtime.c
       /proc/self/cmdline), reads the source file, runs the effect/capability checker
       (aborts the build on violations), codegens C, writes <src>.c, invokes cc → <src>.out.
       Verified: `./zagc fact.zag` builds a binary that prints 720; a @realtime fn that
       allocates is REJECTED ("VIOLATION in hot @realtime", build aborted).

Notes for later stages:
- map.zag must be imported `as map` (its make/get collide with list.zag's); the alias
  propagates through flat re-imports. list.zag is imported flat for ArrayList.
- `|` (bitwise OR) is unusable as a binary op (lexes as capture pipe); use arithmetic.

## Stage C — Bootstrap verification (IN PROGRESS)

- [x] C1. zig-zagc compiles zag-zagc → `zagc2` (selfhost/zagc.zag → ./zagc binary).
- [x] C2a. `zagc2` compiles real programs: fns+recursion (fact→720), structs
       (Point→25), enums (Color.Green→7). Field-access disambiguation by convention
       (capitalized member = enum constant `Enum_Member`; lowercase = struct field
       `x.f`) since the self-hosted codegen is type-unaware.
- [~] C2b. Growing self-hosted codegen to the features selfhost/*.zag uses:
       - [x] CLI: `zag build|check <file> [--run]` (selfhost/zagc.zag → `zag` binary).
       - [x] generic FUNCTIONS via codegen-side monomorphization: parser captures
             fn tparams + explicit call type-args foo[T](..); codegen collects
             instantiations, emits specialized fns (subst type-params in sig),
             mangles call sites. Verified: id[i32]/add[i32] → 42.
       - [x] generic STRUCTS via struct monomorphization + clone-with-substitution:
             ctype mangles Base[args]→Base_args; subst_type substitutes inside [..];
             generic struct literals Foo[T]{..}; clone_block/clone_stmt/clone_expr
             deep-copy generic fn bodies with type-params substituted (Inst.cbody);
             struct instantiations collected from concrete bodies + let-dtys + ret types.
             Verified: Box[T]→42; Pair[i32]→42 & Pair[i64]→123 in one program.
       - [x] @-builtins (@sizeOf[T]/@len/@intCast/@strEq/...) + `as` casts + null,
             with type-param substitution inside monomorphized bodies. Verified the
             full ArrayList allocation pattern: generic struct + extern malloc +
             cap*@sizeOf[T]() + (raw as *T) + pointer indexing → 42.
       - [x] @import in the self-hosted compiler (parse.zag/codegen.zag/zagc.zag):
             - flat merge `@import("p.zag")` with diamond-import dedup (seen-paths set);
             - qualified `@import("p.zag") as name` — true namespacing: module decls
               renamed `name__X`, internal refs + types rewritten, importing-side
               `name.member` / `name.Type` / `name.Type{}` collapsed to the prefix;
               extern fns keep literal FFI names; `mod.Type` handled in parse_type;
             - driver auto-links sibling `runtime.c` of imported modules (cfiles list).
             Limitation: qualifying a module that re-exports a flat-imported generic
             container (map.zag over ArrayList) needs generic-application type descent
             — deferred with the type-inference work below.
       - [x] tagged unions (decl → tag enum + {tag; union u;}; construction → tag+payload),
             STATEMENT switch over unions (`switch(x){ .tag => |cap| {..} }`, __auto_type
             captures) and enums; union/enum identified type-unaware by looking the first
             arm's tag up against the decls; fresh `{ }` block scopes a fixed `__sw` temp.
       - [x] []u8 / ZagSliceU8 prelude + print_str + inline _zag_str_eq/_zag_str_len;
             string literals lowered to `(ZagSliceU8){ptr,len}`; slicing `s[lo..hi]` and
             open-ended `s[lo..]` (new `..` token + Slice node). Pointer-base slicing
             (`container.data[..]`) lowered by shape: a non-deref struct-field base is a
             pointer field (slice directly), else a []T slice value (use .ptr/.len).
       - [x] optionals/orelse + EXPRESSION switch — done WITHOUT a full type-inference
             pass, using two tricks:
             - ?T → `ZagOpt_<T>` struct (typedefs collected from every ?T annotation +
               mono instance); wrapping happens at annotated sites (let dty / fn ret):
               null→{0}, an already-optional (null / call to ?-returning fn)→passthrough,
               bare value→{1,val}. `a orelse b` → `({__auto_type __o=a; __o._has?__o._val:b;})`
               so the use site needs no type.
             - expression switch → a C ternary chain over a `__auto_type __sw` temp,
               with `__auto_type` payload captures; C infers the result type from the
               branches. Works for union and enum value-switches, with/without `else`.
       - [x] qualified import of GENERIC modules — q_subst_type now descends into
             generic applications `Base[args]` (so `as g` renames g's own MapEntry[V]/
             Box[T]), and q_rewrite_expr substitutes call/struct-lit type-args (e.g.
             @sizeOf[MapEntry[V]] → @sizeOf[g__MapEntry[V]]); codegen subst_type also
             handles ?/! prefixes for monomorphizing optional returns. Verified:
             `@import("gmod.zag") as g; g.make_box[i32](42)` → 42 (g__Box_i32 etc.).
       - [x] TYPE-AWARE slice-vs-pointer for index/slice — a small per-function type
             pass (codegen.zag) builds a name→type scope (params + typed lets) and a
             coarse base_type (ident/field/deref/cast/index) over the struct decls,
             then stamps each Index/Slice node's ptr_base flag: `key[i]` ([]u8 →
             key.ptr[i]) vs `e[i]` (*T → e[i]). Plus the supporting fixes it exposed:
             transitive fn-instantiation fixpoint (make[i32]→alloc_table[i32]→grow…),
             struct-instantiation field-dependency ordering (MapEntry[i32] before
             StringMap[i32]), record_type_sinst strips */?/!/[], subst_type handles
             ?/!, opt-typedef collection skips generic templates, join_path passes
             absolute paths, and `zag build --run` prefixes "./" for relative outputs.
       - [x] CAPSTONE: the self-hosted compiler compiles the real std/map.zag
             (StringMap[V]) imported `as map` — generics + *T pointers + slice/pointer
             indexing + ?V optionals + orelse + runtime.c — → 10 20 30 99 3. (test in
             run_selfhost.sh)
       - [ ] if-let `if (opt) |v| {..}` (minor; orelse covers the common consumption).
       (Generic functions/structs + qualified generic imports + optionals/switch/
        strings/slicing all work; the slice-vs-pointer type pass closed the last
        language wall. std/map.zag now compiles end to end.)
- [ ] C3. `zagc2` compiles its own source → `zagc3`; verify fixpoint (zagc2 and
       zagc3 produce identical output). Language features are in place (std/map.zag
       compiles); remaining work is driving the full selfhost/* + std/* source
       through `zagc2` and fixing whatever surfaces (e.g. if-let, std/list.zag,
       larger files), then comparing zagc2/zagc3 output.

## Status log

- 2026-06-23: Plan created. Foundation gaps catalogued. Starting Stage A.
- 2026-06-24: Bootstrap (Zig) compiler — routed all allocations through an arena in
  main.zig; GPA leak report is now clean (0 leaks). Self-hosted compiler — landed
  @import (flat + qualified + runtime.c auto-link), tagged unions + statement switch,
  and []u8/ZagSliceU8 strings + slicing. selfhost suite 10→15 tests.
- 2026-06-24 (cont.): self-hosted codegen — added optionals/orelse, expression switch,
  and pointer-base slicing, all WITHOUT a full type-inference pass (ZagOpt structs +
  wrap-at-annotation, `__auto_type` orelse/captures, ternary-chain expr-switch, shape-
  based pointer-vs-slice). selfhost suite 15→18.
- 2026-06-24 (cont.): qualified import of GENERIC modules (Base[args] type-substitution
  descent + call/struct-lit targ subst + subst_type ?/! ) → selfhost 19.
- 2026-06-24 (cont.): TYPE PASS — a small per-function name→type scope + coarse base_type
  classifies slice-vs-pointer for index/slice (key.ptr[i] vs e[i]); plus transitive
  fn-instantiation fixpoint, struct field-dependency ordering, record_type_sinst prefix
  strip, generic-template opt-collection skip, absolute join_path, `--run` ./ prefix.
  CAPSTONE: the self-hosted compiler now compiles the real std/map.zag (StringMap[V]
  as map) → 10 20 30 99 3. selfhost 19→20; all green (core 40, stdlib 3, selfhost 20,
  selfhost-features 2 = 65 total). C3 next: drive full selfhost/* + std/* through zagc2.
