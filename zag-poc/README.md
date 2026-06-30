# Zag

> **Supported v1 path:** `./znc` compiles Zag directly to static x86-64 ELF.
> It does not invoke C, `cc`, `as`, `ld`, libc, Zig, or LLVM. Run
> `./bootstrap.sh` to self-rebuild and `./tests/run_native_authority.sh` to
> verify that boundary. See [BOOTSTRAP.md](BOOTSTRAP.md).

The C-emitting `./zagc` path documented below is retained as historical POC and
differential-oracle material. It is not the supported compiler, bootstrap
fallback, or release authority.

```sh
./znc examples/numeric.zag -o numeric
./numeric
```

Current native tooling:

```sh
./znc version
./znc init
./znc fmt --in-place source.zag
./znc source.zag -o program --debug
make test
```

The self-hosted LSP lives under `selfhost/lsp/`; the VS Code client is under
`../editors/vscode/`. Six larger native programs and their observed language
gaps are documented in `programs/GAPS.md`.

## Historical Phase 0 record

A real, from-scratch compiler for a subset of **Zag**, proving the one feature that
justifies the language: **the compiler proves capability claims** (`@realtime`,
`@noalloc`, `@total`) instead of trusting a comment.

Pipeline (no Zig, no LLVM yet — those are later phases):

```
.zag --lex--> tokens --parse--> AST --sema(types + EFFECT CHECK)--> C --cc--> native binary
```

## Four "moat" features (real, not stubs)

These target the breaking points developers hit in C/C++/Rust/Zig. Each is
implemented end-to-end through the actual compiler — see the commands.

### 1. Native runtime code patching (hot-reloading)
Edit a function and swap it into a **running** process without a restart; live
memory state is retained. The `--hot` backend routes every Zag→Zag call through
a per-function pointer in a dispatch table; the linked runtime
(`src/zag_hotreload.c`) `dlopen`s a freshly compiled patch `.so` and atomically
re-aims those pointers at the new code at a safe point (SIGUSR1-driven).
```bash
bash examples/hotreload_demo.sh     # builds --hot, runs, live-patches label(), shows 1xxx→2xxx
                                    # while the loop counter keeps climbing (state retained)
# manual:
zagc build --hot examples/hot_demo.zag        # host with a swappable dispatch table
zagc hot-patch hot_demo.zag -o hot_demo_patch.so   # compile a live patch
kill -USR1 <pid>                              # the running host swaps it in
```
Honest boundary: patch granularity is a whole function via an atomic pointer
swap at a safe point (single-threaded-safe), not mid-instruction machine-code
rewriting.

### 2. AI-native structured diagnostics
First-class machine-readable JSON for the three things an agent needs — instead
of regex-scraping stderr. Diagnostics carry the **effect witness chain**; the
AST is type-annotated; the dep graph carries declared annotations *and* inferred
effects.
```bash
zagc check examples/audio_render_bad.zag --json   # diagnostics + capability witness chains
zagc ast   examples/interfaces.zag                # type-annotated AST as JSON (schema zag.ast/v1)
zagc deps  examples/audio_render.zag              # call/effect dependency graph (zag.depgraph/v1)
```

### 3. Compile-time structural ("duck") typing
No `implements`, no hand-written vtables, no `anyopaque`/`void*` plumbing. The
compiler scans each type's method set; if it structurally matches an interface,
it **auto-emits** the vtable + adapter thunks and lets the value be passed where
the interface is expected. A missing/mismatched method is a precise error.
```bash
zagc build examples/interfaces.zag --run    # Square & Rect satisfy Shape structurally → 75, 36
```
```zag
interface Shape { fn area(self) i32; fn scaledArea(self, factor: i32) i32; }
fn report(s: Shape) i32 { return s.area() + s.scaledArea(2); }   // dispatches via synthesized vtable
```

### 4. Immutable lockfile toolchains (`zag.mod`)
A non-optional project manifest pins the compiler version, language **edition**,
and required features. The compiler walks up from the source, parses it, and
**enforces** it before lowering a token — a mismatch is a hard, actionable error,
never a mystery parse failure. Solves the "no-indicator versioning trap."
```bash
zagc version                         # zagc 0.1.0 (edition phase0, build poc-phase0)
zagc init myproject                  # write a zag.mod pinned to this compiler
zagc build examples/numeric.zag      # discovers repo-root zag.mod, reports it satisfied
zagc check file.zag --locked         # CI mode: missing zag.mod is fatal
```
A project pinned to `zag = "^0.2.0"` / `edition = "phase1"` is refused by this
0.1.0/phase0 compiler with an explanation, instead of miscompiling.

## Run it

```bash
# GOOD: a realtime audio render block — proven clean, compiled, run
zagc build examples/audio_render.zag --run

# BAD: an allocation buried 3 calls deep inside @realtime — rejected with the call chain
zagc check examples/audio_render_bad.zag

# GOOD: mathpressor-shaped @noalloc synth + @total quantizer
zagc build examples/synth.zag --run

# BAD: @total with a runtime divisor — rejected (the honest Z3 boundary)
zagc check examples/total_bad.zag

# BAD: @realtime that locks and does IO — both rejected
zagc check examples/realtime_io_lock_bad.zag

# ── EFFECT POLYMORPHISM (the keystone) ──
# GOOD: generic processBlock proven @realtime via the callback you pass; runs
zagc build examples/process_poly.zag --run
# BAD: same generic with an allocating callback — witness crosses the generic boundary
zagc check examples/process_poly_bad.zag
# GOOD: generic self-annotated @realtime via a BOUNDED callback type; runs
zagc build examples/process_bounded.zag --run
# BAD: call-site bound violation, caught even though main is unannotated
zagc check examples/process_bounded_bad.zag
```

# ── TYPE-LEVEL EFFECT VARIABLES (effects flow through values) ──
zagc build examples/effvar_local.zag --run    # callback in a typed local
zagc build examples/effvar_return.zag --run   # effect flows out of a return
zagc check examples/effvar_local_bad.zag      # rejected at the STORE

# ── STRUCTS + REAL SLICES (.len) ──
zagc build examples/struct_basic.zag --run

# ── CAPSTONE: callback stored in a struct field, called on the audio thread ──
zagc build examples/voice_struct.zag --run    # proven realtime-safe, runs
zagc check examples/voice_struct_bad.zag      # allocating op rejected at construction

# ── CLOSURES (explicit capture, no heap) ──
zagc build examples/closure_basic.zag --run   # captures gain on the stack; runs
zagc build examples/closure_effvar.zag --run  # closure instantiates effect var ! e
zagc check examples/closure_bad.zag           # allocating closure rejected at realtime
zagc check examples/closure_effvar_bad.zag    # effect flows through ! e and is caught
zagc check examples/closure_escape_bad.zag    # capturing closure can't escape (no heap)

# ── GENERICS OVER TYPES (monomorphization) ──
zagc build examples/generic_box.zag --run     # Box[T] + unbox[T] at i32 and f32
zagc build examples/generic_map.zag --run     # generic mapInPlace[T] at f32 and i32
zagc build examples/generic_map_rt.zag --run  # generic map + closure on audio thread, proven realtime
zagc check examples/generic_map_rt_bad.zag    # effect crosses the generic+closure boundary
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
counterexample (`a=0, d=0`). Prover selection is automatic (`ghost_engine` | `z3` | `none`);
`GHOST_ENGINE`/`GHOST_VERIFY` override the path. With no prover the legacy `./zagc` differential
path degrades to the conservative rule, so `run_tests.sh` (prover-independent programs) still
passes without an external prover.

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
