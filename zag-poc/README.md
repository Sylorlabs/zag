# zag-poc — Zag bootstrap compiler (Phase 0)

A real, from-scratch compiler for a subset of **Zag**, proving the one feature that
justifies the language: **the compiler proves capability claims** (`@realtime`,
`@noalloc`, `@total`) instead of trusting a comment.

Pipeline (no Zig, no LLVM yet — those are later phases):

```
.zag --lex--> tokens --parse--> AST --sema(types + EFFECT CHECK)--> C --cc--> native binary
```

## Run it

```bash
# GOOD: a realtime audio render block — proven clean, compiled, run
python3 zagc.py build examples/audio_render.zag --run

# BAD: an allocation buried 3 calls deep inside @realtime — rejected with the call chain
python3 zagc.py check examples/audio_render_bad.zag

# GOOD: mathpressor-shaped @noalloc synth + @total quantizer
python3 zagc.py build examples/synth.zag --run

# BAD: @total with a runtime divisor — rejected (the honest Z3 boundary)
python3 zagc.py check examples/total_bad.zag

# BAD: @realtime that locks and does IO — both rejected
python3 zagc.py check examples/realtime_io_lock_bad.zag

# ── EFFECT POLYMORPHISM (the keystone) ──
# GOOD: generic processBlock proven @realtime via the callback you pass; runs
python3 zagc.py build examples/process_poly.zag --run
# BAD: same generic with an allocating callback — witness crosses the generic boundary
python3 zagc.py check examples/process_poly_bad.zag
# GOOD: generic self-annotated @realtime via a BOUNDED callback type; runs
python3 zagc.py build examples/process_bounded.zag --run
# BAD: call-site bound violation, caught even though main is unannotated
python3 zagc.py check examples/process_bounded_bad.zag
```

# ── TYPE-LEVEL EFFECT VARIABLES (effects flow through values) ──
python3 zagc.py build examples/effvar_local.zag --run    # callback in a typed local
python3 zagc.py build examples/effvar_return.zag --run   # effect flows out of a return
python3 zagc.py check examples/effvar_local_bad.zag      # rejected at the STORE

# ── STRUCTS + REAL SLICES (.len) ──
python3 zagc.py build examples/struct_basic.zag --run

# ── CAPSTONE: callback stored in a struct field, called on the audio thread ──
python3 zagc.py build examples/voice_struct.zag --run    # proven realtime-safe, runs
python3 zagc.py check examples/voice_struct_bad.zag      # allocating op rejected at construction

# ── CLOSURES (explicit capture, no heap) ──
python3 zagc.py build examples/closure_basic.zag --run   # captures gain on the stack; runs
python3 zagc.py build examples/closure_effvar.zag --run  # closure instantiates effect var ! e
python3 zagc.py check examples/closure_bad.zag           # allocating closure rejected at realtime
python3 zagc.py check examples/closure_effvar_bad.zag    # effect flows through ! e and is caught
python3 zagc.py check examples/closure_escape_bad.zag    # capturing closure can't escape (no heap)

# ── GENERICS OVER TYPES (monomorphization) ──
python3 zagc.py build examples/generic_box.zag --run     # Box[T] + unbox[T] at i32 and f32
python3 zagc.py build examples/generic_map.zag --run     # generic mapInPlace[T] at f32 and i32
python3 zagc.py build examples/generic_map_rt.zag --run  # generic map + closure on audio thread, proven realtime
python3 zagc.py check examples/generic_map_rt_bad.zag    # effect crosses the generic+closure boundary
```

Run everything at once: `bash run_tests.sh` (24 programs: 14 build+run, 10 rejected).

### Phase 3 — proofs discharged by the actual ghost_engine
The conservative rule flags any non-literal divisor as a possible trap. The verification pass
symbolically executes a `@total` function, tracks the path condition, and for each division emits
an **SMT-LIB2** verification condition that it hands to **ghost_engine** — the binary
`ghost_engine/zig-out/bin/zag_verify` (source `ghost_engine/src/zag_verify.zig`), which discharges
it through the engine's own Z3 bridge (`Z3_eval_smtlib2_string`, the same path `verified_swap.zig`
uses). `unsat` ⇒ proven; `sat` ⇒ counterexample; else ⇒ unproven (sound).

Build the bridge once, then run:
```bash
( cd ../../ghost_engine && zig build zag-verify )   # builds zig-out/bin/zag_verify (links system libz3)
bash prove.sh
```
You'll see `total_guarded` (`if (d!=0) a/d`) and `total_nonzero` (`x/(n*n+1)`, no guard) **proven
by ghost_engine** (`🔒 ghost_engine proved …`), and `total_bad` rejected with a concrete
counterexample (`a=0, d=0`). Prover selection is automatic (`Sema.prover_name()` →
`ghost_engine` | `z3-python` | `none`); `GHOST_ENGINE`/`GHOST_VERIFY` override the path. With no
prover the compiler degrades to the conservative rule, so `run_tests.sh` (24 prover-independent
programs) still passes under plain `python3`.

### Effect polymorphism + effect variables (verified)
A capability system is a toy unless it composes. Working here:
- **Call-site inference** — an un-annotated generic is proven per call site; the witness
  crosses the boundary: `renderBad → processBlock → fancyOp → zalloc()`.
- **Bounded callback types** — `op: fn(f32) f32 @realtime` lets a generic be `@realtime` and
  checks each call site.
- **Effects as part of the type, flowing through values** — `fn(f32) f32 ! pure` / `! {Alloc}`
  / `! e`. Effects propagate through function-typed **locals**, **returns**, and **struct
  fields**. A callback stored in an `@realtime` struct field and called on the audio thread is
  proven safe; storing an allocating op there is rejected at construction.

- **Closures, allocation-free** — `fn[gain](x: f32) f32 { x * gain }` captures by value into a
  *stack* environment (codegen: `&(__ClosEnv){ .gain = gain }`, zero `malloc`). The closure's
  effect is read off its body and **instantiates the effect variable `! e`** when passed to a
  generic — a pure closure proves `@realtime`, an allocating one is rejected with a witness
  through the variable. Price: a capturing closure may not escape its scope (returning one is
  a compile error; escaping closures need heap = Phase 1).

- **Generics over types (monomorphization)** — `fn map[T](xs: []T, f: fn(T) T)`, `struct Box[T]`.
  Generic fn calls **infer** `T` from args; generic structs use explicit `Box[i32]`. Each
  instantiation generates a concrete copy (`Box_i32`, `map_f32`) — zero runtime cost. Crucially,
  **effects compose through generics**: the same `map` is proven realtime with a pure closure
  and rejected with an allocating one, witness crossing both boundaries:
  `renderBad → mapInPlace[f32] → closure → zalloc()`.

Remaining (Phase 1): escaping (heap) closures, row-polymorphic inference for fully opaque
values, methods/enums, generic bounds. See `../ZAG_DESIGN.md` §2.4 / §2.4.1.

### Structs + real slices
`struct Name { f: T, ... }`, construction `Name{ .f = v }`, field access `x.f`. Slices are
`{ptr, len}` values — `buf.len` works, indexing is bounds-carrying-capable (bounds *proof*
is Phase 3/Z3). Codegen emits real C structs and function-pointer typedefs.

`build` also takes `-o <out>` and `--emit-c` (emit C, don't compile).

## What's real here (verified, not claimed)

- Hand-written **lexer** and recursive-descent **parser** for the subset grammar.
- A **sound effect checker** over the call graph: `Alloc`, `Lock`, `IO`, `Panic`.
  Annotations are *claims*; the checker proves or refutes them and prints a witness
  chain (`renderBlock → gain → reverbScratch → zalloc()`).
- A **C backend** that emits real C and invokes the system `cc` to produce a native
  binary that runs.
- Demonstrated catches for all four effects; demonstrated native execution of the two
  valid programs.

## What is deliberately NOT here (the honest boundary)

- **Z3 / deep proofs.** `@total` only auto-proves the divisor=nonzero-literal case. The
  general "this index is in bounds / this divisor is nonzero given the guards" reasoning
  is exactly what `ghost_engine` already does with Z3, and it is **Phase 3** (see
  `../ZAG_DESIGN.md` §2.3). z3 isn't even installed on this box — the boundary is real,
  not hidden.
- **Types beyond `i32/f32/bool/void` and `[]f32/[]i32`.** No structs, no generics, no
  real slices-with-length, no strings. So it CANNOT compile your existing `.zig` files —
  Zag is a different language and this is a subset. The examples are hand-ported *slices*
  of the DAW/ mathpressor shapes, not your literal source.
- **Closures, error-context, FFI generation, the stdlib.** All Phase 1+.

## Known rough edges
- Capability error points at the function's declaration line, not the offending
  statement (the witness chain names the real culprit, so it's locatable).
- No name-shadowing handling (Zag doesn't allow it; the examples don't need it).

Completeness vs. "a language you could ship mathpressor in": **single digits.** This is a
proof of the core idea, on purpose.
