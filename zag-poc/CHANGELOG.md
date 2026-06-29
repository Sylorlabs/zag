# Changelog

All notable changes to Zag are documented here. Dates are commit dates in
Pacific Time. Tags are listed in chronological order; all tags preceded
`2026.06.0-dev` — the CalVer scheme begins with the first formal release.

---

## [Unreleased] — 2026-06-29

Work on the `native-self-hosting-no-zig` branch after `v0.4-numerics-native`.

### Added
- **vsa_b\<N\> bitwidth vector operators**: XOR, OR, AND on `vsa_b<N>` types;
  per-program dimension scan so `ZAG_VSA_DEFINE` macros are emitted once per
  unique width.
- **Numeric sub-slicing**: word-stride slicing of `[]u3`..`[]u127` and other
  packed-width numeric slices in `ncodegen`.
- **Error propagation hardening** (`sema`): bare `!T` calls assigned to a
  non-`!T` binding without `catch`/`try` are now a hard semantic error.
- **Closure pointer captures**: closures can capture by pointer (`*T`) in
  addition to by value; `fat_fn` struct layout extended accordingly.
- **LSP server**: a Language Server Protocol implementation self-hosted in Zag
  (`selfhost/lsp/`); supports completion and rename; reads source via
  `_zag_read_fd`.
- **Module system** (`@import` with qualified paths, `zag.mod` dependency
  resolution via `zagmod.zag`).
- **Stdlib additions**: `sort`, `hashmap`, `strbuf` modules added to `std/`.
- **`!T` error propagation** (`try`/`catch`/`!T` type syntax) across the full
  pipeline (parse → sema → ncodegen).
- **Type inference**: `let x = expr;` infers the type from the right-hand side
  in both `zagc` and `znc`.
- **Structural interfaces**: `interface` keyword; compiler auto-emits vtables
  and thunks — zero boilerplate.
- **`@total` path-sensitive prover**: algebraic discharge of termination proofs
  including early-exit guards and product divisors (ghost engine, `prove.sh`).
- **Operator contracts**: user-defined `+`/`-`/`*` on custom types via an
  operator contract declaration; lowered before sema.
- **Cache builtins**: `@cacheAlignedAlloc`, `@prefetch`, `@cacheLineSize`.
- **Generics in the native backend**: type-argument inference for generic
  functions and structs; `!T` error unions; `fat_fn` struct sizing.
- **Closures in the native backend**: `fat_fn` (closure + captured-env pointer)
  support; `while let` syntax.
- **`let x: T;`** (let without initialiser): `has_init` field added to the
  `Let` AST node.
- **ZIR**: a lightweight MLIR-shaped in-memory IR (`selfhost/zir.zag`); `znc
  zir`/`znc zirc` sub-commands dump or compile via it.
- **Sensor pipeline demo** and hot-reload (`--hot` flag).
- **`zagc` demoted to differential oracle**: `./zagc` (C-emitting backend) is
  now explicitly NOT a supported build path; `./znc` is the only supported
  compiler.

### Changed
- `zagc` is now labelled "historical bootstrap material and differential oracle"
  in `BOOTSTRAP.md`; it is not a release artifact.
- `bootstrap.sh` is the only supported rebuild path; it uses `znc` exclusively.

---

## [v0.4-numerics-native] — 2026-06-27

Tag: `v0.4-numerics-native`

The entire heterogeneous numeric type system ported into the native `znc`
machine-code backend. Numeric programs now compile straight to x86-64 ELF with
no `cc`, `as`, `ld`, `libc`, `Zig`, or `LLVM`.

### Added
- **Posit arithmetic in the native backend** (Track 2 round 1): `posit32`,
  `posit16`, `posit8` types; `padd`/`psub`/`pmul`/`pdiv` via hardware-posit
  instructions (ppu32 target) or software emulation.
- **Saturating / fixed-point / arbitrary-width / `[]numeric` in the native
  backend** (Track 2 round 2): `sat_i8`..`sat_u64`, `fixed_I_F` Q-format types,
  `u3`..`u127` arbitrary-width integers, and slices thereof.
- **RNS and 512-bit quire in the native backend** (Track 2 round 3):
  `rns_N` residue-number-system types and the 512-bit quire accumulator for
  exact posit dot-products.
- `native/numeric_rt.zag`: runtime helpers for numeric types compiled into the
  ELF text segment (no external library).

### Changed
- `native/ncodegen.zag`: extended to handle all numeric type nodes from
  `parse.zag`.
- `native/print_i32`/`print_u32` correctly truncate to 32 bits (matching C
  `printf %d/%u` behaviour in differential tests).

---

## [v0.3-cc-free] — 2026-06-26

Tag: `v0.3-cc-free`

The entire toolchain (`zagc` driver, `znc` native compiler, stdlib, examples)
now builds via `znc` with **zero external tools** — no `cc`, `as`, `ld`, `Zig`,
`LLVM`, or `libc`.

### Added
- `bootstrap.sh`: cc-free rebuild of the whole toolchain using only `./znc`.
- `tests/run_native_authority.sh`: authoritative release gate; poisons host C
  tools, rebuilds the compiler from source, runs the native test suite.

### Fixed
- `_zag_println` on a `[]u8` slice was silently dropping the trailing newline.
- Switch-arm capture expression reuse was under-reserving the stack frame.
- `orelse` in call-argument position was miscompiled.

---

## [v0.2-phase-d-optim] — 2026-06-26

Tag: `v0.2-phase-d-optim`

Phase D: the native optimizer. Three passes added on top of the Phase C stack
machine; collectively they close most of the performance gap with the C backend.

### Added
- **Register-promotion pass** (`native/regalloc.zag`): promotes frequently used
  stack slots to caller-saved registers (`r10`..`r15`) where live-range allows.
- **Constant-folding + stack-temp elimination** (`native/optimize.zag`): folds
  arithmetic on immediates at compile time; eliminates push/pop pairs for
  expression temporaries that never alias.
- **Immediate-selection pass** (`native/peephole.zag`): converts `mov rN, imm64`
  + `op rN, rM` to `op rN, imm32` where the constant fits, reducing code size.
- Phase C round 1: floating-point (`f64`/`f32`) in the native backend; `f32` is
  promoted to `f64` internally; `sinf`/`cosf`/`sqrtf` via SSE2 instructions.

### Changed
- `znc` pipeline is now: parse → sema → lower → regalloc → optimize → peephole →
  encode → ELF.

---

## [v0.1-native-selfhost] — 2026-06-26

Tag: `v0.1-native-selfhost`

**Zag builds Zag.** The Zig bootstrap (`src/*.zig`, `build.zig`, ~10 500 lines)
is deleted. The toolchain now bootstraps from a committed seed binary (`./znc`).

### Added
- `selfhost/native/znc.zag`: CLI driver for the native backend.
- `selfhost/native/ncodegen.zag`: AST → x86-64 instruction lowering.
- `selfhost/native/x86.zag`: x86-64 instruction encoder.
- `selfhost/native/elf.zag`: ELF executable writer (no linker).
- `selfhost/native/isa.zag`: instruction set abstraction (`Instr` type).
- `selfhost/native/regalloc.zag`: register allocator skeleton (Phase D).
- `selfhost/native/elf_obj.zag`: static library reader (`ar` format, ELF `.o`).
- `selfhost/native/ar.zag`: GNU `ar` archive symbol-table reader.
- `selfhost/native/zagmod.zag`: `zag.mod` manifest parser.
- `selfhost/mlir.zag`: MLIR/GPU backend written entirely in Zag (Python and Zig
  GPU middlemen deleted).
- `selfhost/zir.zag`: lightweight MLIR-shaped in-memory IR; no LLVM.
- Self-hosting fixpoint: `znc` compiles `znc.zag` to produce a byte-identical
  copy of itself.

### Removed
- `src/*.zig` — the entire Zig bootstrap (~10 500 lines).
- `build.zig` — the Zig build system file.
- `gpu/*.py` and `src/gpu_mlir.zig` — Python/Zig GPU middlemen.

---

## [v0.0-zig-bootstrap] — 2026-06-24

Tag: `v0.0-zig-bootstrap`

The last state with the Zig bootstrap. The seed compiler.

### Summary

This tag marks the state immediately before the native-self-hosting transition.
The full compiler is a ~10 500-line Zig program (`src/*.zig`) that emits C code,
which `cc` then compiles. The self-hosted Zag stages were already developed
(`selfhost/lex.zag`, `parse.zag`, `sema.zag`, `codegen.zag`, `zagc.zag`,
`astjson.zag`, `mlir.zag`) and had reached fixpoint (the C-backend Zag compiler
compiled itself and reproduced identical C output). The native backend existed in
skeleton form but had not yet reached full parity.

### The bootstrap chain at this tag

```
Python (zagc.py, retired)
  → Zig bootstrap (src/*.zig)
    → self-hosted C-backend (selfhost/*.zag → cc → binary)
      → native backend (selfhost/native/*.zag, not yet fully self-hosting)
```

### Notable features already present at v0.0

- Effect / capability system: `@realtime`, `@noalloc`, `@pure`, `@total`
  annotations checked by `selfhost/sema.zag`.
- Generic functions and structs with type-argument inference.
- Heterogeneous numeric type system: `posit32`, `posit16`, `posit8`, `quire`,
  `sat_i8`..`sat_u64`, `fixed_I_F`, `u3`..`u127`, `rns_N`, `u_any` bignum;
  `vsa_b<N>` vector-superaccumulator bitwidth types.
- GPU / MLIR backend (NVIDIA, AMD, Vulkan) via `selfhost/mlir.zag`.
- Structural interfaces, `interface` keyword, vtable synthesis.
- Hot-reload (`--hot` flag), AI-native JSON (`--json`/`ast`/`deps`).
- `zag.mod` lockfile (`init`, `version`, `--locked`).
- 46/46 C-backend self-hosting tests passing; 28/28 semantic tests passing.

---

## Earlier history (pre-tag)

| Commit    | Date       | What happened                                                   |
|-----------|------------|-----------------------------------------------------------------|
| `d881ff6` | 2026-06-?? | Initial commit                                                  |
| `192c4db` | 2026-06-?? | Add Zag PoC compiler: effect system, GPU/MLIR backend, numerics |
| `bc2410c` | 2026-06-?? | Comprehensive README; install / quick-start / how it works      |
| `d0d4b34` | 2026-06-?? | Rewrite Zag compiler from Python (`zagc.py`) to Zig 0.14       |
| `2644278` | 2026-06-?? | Add `*T` pointer types + stdlib foundation for self-hosting     |
| `1347b29` | 2026-06-?? | Self-hosted lexer (`lex.zag`) + enabling language features      |
| `793085e` | 2026-06-?? | Self-hosted AST + recursive-descent parser (`ast.zag`, `parse.zag`) |
| `5eba184` | 2026-06-?? | Self-hosted effect checker (`sema.zag`)                         |
| `9bd4b8b` | 2026-06-?? | Self-hosted C backend (`codegen.zag`)                           |
| `9cfce47` | 2026-06-?? | Self-hosted driver (`zagc.zag`) — Zag compiling Zag end-to-end  |
| `928fac2` | 2026-06-?? | FIXPOINT — Zag C-backend compiler reproduces identical C output |
