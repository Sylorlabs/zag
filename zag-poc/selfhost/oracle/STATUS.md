# Differential Oracle Status

The differential oracle is a tree-walking interpreter (`selfhost/oracle/interp.zag`)
that executes a subset of Zag and a runner (`selfhost/oracle/run_diff.sh`) that
verifies the interpreter's stdout matches the C backend's stdout for each test
case. The C backend (`zagc`) is the reference until the interpreter's verified
set covers everything `zagc` covers; only then can `zagc` be retired.

## Verified today (10/10)

Each test is a Zag program. The runner compiles it via `zagc` and via `znc`
+ the interpreter, then diffs stdout.

| # | Test         | Verifies                                              | Output |
|---|--------------|-------------------------------------------------------|--------|
| 1 | fib          | recursion, params, int arithmetic, print_i32         | 55     |
| 2 | let_arith    | let with init, int arithmetic                         | 22     |
| 3 | ifelse       | if/else, comparison, multiple branches                | 1 -1   |
| 4 | while        | while loop, iterative sum                             | 55     |
| 5 | i64          | i64 type, 4-billion round-trip                        | 4000000000 |
| 6 | len          | @len() builtin on []u8                                | 5      |
| 7 | i64_while    | combination: i64 + while + add                        | 55     |
| 8 | idx          | slice indexing s[2] as i32                            | 99     |
| 9 | sum_bytes    | combination: idx + while + add over a string          | 294    |
| 10 | len_field   | .len field access (vs @len builtin)                  | 5      |

## Supported surface (interpreter)

- int literals (i32, i64) — parsed as i64, narrowed via declared type
- identifiers (locals)
- binary: + - * / < > <= >= == !=
- unary: -
- call: to user-defined fns (i32/i64 params), plus builtins:
  - print_i32, print_i64, print_u64, print_f32, print_f64
  - @len
- if / if-else
- while (return propagates out)
- return
- let (with i32/i64/u32/u64/f32/f64 declared type, or untyped)
- assign (locals only)
- cast_ (identity at runtime)
- field access: only `.len` on []u8 slices
- indexing: s[i] on []u8 slices (reads from heap-allocated string buffer)
- string literals: stored in heap buffer, accessible via @len and s[i]
- bool coercion: 0 → 0, anything else → 1
- function recursion (via the Zag call stack)

## Out of scope (deferred, with comments at the deferred sites)

- **print_str of non-empty strings.** Requires a new native-runtime symbol
  (`_zag_pstr` or similar) in `selfhost/native/ncodegen.zag`'s RT_* dispatch
  table, plus matching extern declarations in `std/rt.zag` and a one-line C
  implementation in `std/runtime.c`. The interpreter's `emit_str_ln` is a
  stub that prints a marker.
- **struct literals and field access beyond `.len`.** Required for the
  standard library (ArrayList, Map, etc.). The AST nodes (`.slit_`, `.struct_`)
  fall through to default 0 today.
- **enum, union, generic instantiation.**
- **closures and function-typed parameters.** Real example programs
  (`examples/closure_*.zag`, `examples/effvar_*.zag`) use these.
- **slices of types other than `[]u8`** (e.g. `[]f32`, `[]i32`).
- **the heterogeneous numeric tower** (p32, sat_i16, etc.).
- **slice assignment `s[i] = v`** (only reads are supported).
- **the codegen type pass** (which would stamp `ptr_base` for `s[i]` and
  type info for fields). The interpreter tolerates the default
  `ptr_base=1` by inspecting value tags at dispatch time.

## Architecture decisions

- **Value representation: `{tag, bits}`.** A tagged i64 holds int, f32 (as
  f64), or a pointer to a heap-allocated string buffer. f64/f32 share
  `bits` (cast at use). Heap strings have layout `{i32 len, u8[len] data}`.
- **No codegen type pass.** The interpreter evaluates AST nodes directly
  with the value's runtime tag providing type information at dispatch
  time. This is simpler than running the full type pass, at the cost of
  missing some programs that rely on type-driven lowering (e.g. struct
  layout).
- **Function dispatch via FnTable.** At run setup, every `fn` decl is
  registered by name. Calls look up by name. No closures yet.
- **No allocation in the interpreter for values.** Only string buffers
  are allocated (via `_zag_malloc` from `std/rt.zag`). The interpreter
  is itself a Zag program and inherits the runtime's allocator.

## How to grow the verified set

1. Add a new `XXX_SRC` string in `run_diff.sh` with a small Zag program.
2. Add a `run_test "xxx" "$XXX_SRC"` line at the bottom of the runner.
3. If the test fails, the failure mode is one of:
   - The interpreter doesn't handle an AST node: the default case returns
     `v_i32(0)`, which usually diverges from the C backend.
   - The interpreter's value representation doesn't carry enough info
     (e.g. struct fields, slice element type).
   - A new builtin's lowering is missing.
4. Add the missing handler in `interp.zag`, re-run, commit.

Each test should be the *smallest* program that exercises one new feature.
The 10/10 suite today is roughly 4-5 features above the original 3/3
commit, with two of those being "combination" tests that catch
interaction bugs.

## Build and run

```
cd /home/micah/Desktop/Sylorlabs/zag/zag-poc
./selfhost/oracle/run_diff.sh
```

The runner expects `./znc` and `./zagc` to exist at the `zag-poc/` root
and `../zag-poc/znc` and `../zag-poc/zagc` from the flash project. Both
are seeded; the runner does not rebuild them.

## What's needed to retire `zagc`

The C backend can be retired when the interpreter can run the same
programs that `zagc` runs and produce the same stdout. Concretely, that
means every example program in `examples/*.zag` and every test program
in `tests/` and `tests/integration/` must pass the differential test
against the interpreter.

Today the interpreter covers a small fraction of the language. The
remaining work is mostly:

1. **Structs.** Unlocks ArrayList, Map, and most of the standard library.
2. **Closures + function-typed params.** Unlocks `examples/closure_*.zag`
   and `examples/effvar_*.zag`.
3. **print_str.** Small but required for any program that emits strings.
4. **Slice assignment.** Required for any non-trivial program that
   mutates a buffer.

These are each their own multi-day piece of work. The oracle's
incremental growth model (one feature, one test) means each of them
becomes its own commit on the way to `zagc` retirement.

## Related branches

- `main` (this branch's parent) — has the WIP aarch64 work preserved
  on `wip/preserve-2026-06-30`
- `wip/preserve-2026-06-30` — preserves the aarch64 WIP from main
- `archive/c-backend-oracle` — preserves the C backend source for
  rollback; will be the only place `zagc` exists once it's retired
- `wip/retire-c-backend-2026-06-30` (this branch) — work in progress on
  the differential oracle. The C backend remains in the working tree
  for now; retirement happens after the oracle's verified set covers
  everything zagc covers.
