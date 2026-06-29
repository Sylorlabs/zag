# Zag ABI and Language Stability Guarantees

This document is an engineering contract. It specifies the binary interface and
language guarantees Zag programs can rely on, and what remains explicitly
unstable. See `VERSIONING.md` for the versioning scheme and tier overview.

---

## Supported Compiler

The only **supported** Zag compiler is `./znc` (the native backend,
`selfhost/native/znc.zag`). It emits x86-64 ELF executables with no `cc`, `as`,
`ld`, `libc`, `Zig`, or `LLVM` involvement.

`./zagc` (the C-emitting backend, `selfhost/codegen.zag`) is a **differential-
testing oracle**. It is not a release artifact, not a supported build path, and
carries no ABI, CLI, or language-compatibility guarantees.

---

## Struct Layout

Rules apply to structs compiled by `znc`. The layout rules below are implemented
in `selfhost/native/ncodegen.zag` (`size_of` / field-offset computation).

| Rule | Specification |
|------|---------------|
| Field order | Fields are laid out in declaration order; no reordering. |
| Alignment | Each field is placed at the next offset that is a multiple of `min(field_size, 8)`. |
| First field | Always at offset 0. |
| Padding | Trailing padding is added so `sizeof(Struct)` is a multiple of the struct's largest field alignment (max 8 bytes). |
| `[]u8` fat slice | Always 16 bytes: 8-byte pointer followed by 8-byte length (both `i64`-width). |
| `*T` pointer | Always 8 bytes (one 64-bit word). |
| `bool` | 1 byte (`u8`), sign-extended to 8 bytes when loaded into a register. |
| `i32` / `u32` | 4 bytes. Zero-extended to 64 bits in registers. |
| `i64` / `u64` | 8 bytes. |
| `f64` | 8 bytes. Stored in a general-purpose register (bit-cast); moved to `xmm0` for arithmetic. |
| `f32` | 4 bytes in memory; **promoted to `f64`** inside the compiler for all arithmetic. |
| `fat_fn` (closure) | 16 bytes: 8-byte code pointer + 8-byte captured-environment pointer. |
| Arbitrary-width `u3`..`u127` | Stored in the smallest power-of-two byte count that fits (1, 2, 4, 8, 16 bytes). |
| `posit32` / `sat_i8` etc. | Same width as the underlying integer representation (4 / 1 bytes, etc.). |

**ABI status: unstable.** Language v1 does not freeze binary layout.

---

## Calling Convention

`znc` follows **System V AMD64** with the extensions below. This is documented
in `selfhost/native/ncodegen.zag` (line 13).

### Integer / pointer arguments

Passed left-to-right in: `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`.
Additional arguments beyond 6 go on the stack in right-to-left order (standard
SysV stack passing).

### Slice arguments (`[]T`)

A `[]T` slice is two consecutive arguments: the **pointer** in register N and
the **length** in register N+1. For example, the first slice argument occupies
`rdi` (ptr) and `rsi` (len); the second occupies `rdx` (ptr) and `rcx` (len);
and so on. If the first argument is a scalar, the first slice occupies `rsi`
(ptr) + `rdx` (len).

### Return values

| Type | Return location |
|------|-----------------|
| `i32`, `i64`, `u32`, `u64`, `bool`, `*T` | `rax` |
| `f64` / `f32` | `xmm0` (f32 is promoted to f64) |
| `[]T` (fat slice) | `rax` = pointer, `rdx` = length (two-register return) |
| Struct | Passed as an implicit first argument (pointer in `rdi`); callee writes through it; no value in `rax`. |

### Caller-saved vs callee-saved

Follows SysV AMD64: `rbx`, `rbp`, `r12`–`r15` are callee-saved. `rax`, `rcx`,
`rdx`, `rsi`, `rdi`, `r8`–`r11`, `xmm0`–`xmm15` are caller-saved.

`znc` currently uses `r10`–`r15` for register-promoted temporaries (see
`regalloc.zag`); these are callee-saved per SysV so they are saved/restored in
prologues when used.

### Stack alignment

The stack is 16-byte-aligned at every `call` instruction, per SysV AMD64.
Frame sizes are always rounded up to a multiple of 16.

### Deviations from SysV AMD64

1. **Struct return is always by pointer** (rdi out-pointer), even for structs
   ≤ 16 bytes. SysV returns small structs in `rax`:`rdx`; Zag does not.
2. **`f32` is promoted to `f64`** internally; there is no distinct `f32`
   register protocol (no `xmm0`-with-single-precision semantics).

**ABI status: unstable.** Language v1 does not freeze the calling convention.

---

## ELF Symbol Mangling

**Current status: unmangled and ABI-unstable.**

`znc` emits the raw Zag function name as the ELF symbol, with one runtime
prefix:

| Symbol kind | Current edition 2026 | Reserved future form |
|-------------|-------------------|----------------|
| `pub fn foo()` | `foo` | `_zag_foo` |
| `fn foo()` (private) | `foo` (local, `STB_LOCAL`) | `foo` (no export) |
| Module-qualified: `mod.fn` | `mod__fn` (double-underscore) | `_zag_M_mod__fn` |
| Runtime helpers | `_zag_*` (stable now) | `_zag_*` (unchanged) |

The `_zag_*` prefix on runtime helpers (`_zag_println`, `_zag_read_file`, etc.)
is **stable from the first release** — these names are already baked into the
runtime object and will not change.

**Module mangling rule** (edition 2026): `import("foo/bar.zag")` → functions in
that module are prefixed `foo__bar__` in the symbol table. `_zag_M_` is reserved
as a possible future ABI-edition form; no transition date is promised.

---

## Effect Annotations

The four core effect annotations are **stable** as of `2026.06.0`:

| Annotation | Meaning | Guarantee |
|------------|---------|-----------|
| `@realtime` | Function must not allocate, block, or call non-`@realtime` fns | Stable |
| `@noalloc` | Function must not allocate heap memory | Stable |
| `@pure` | Function has no observable side effects | Stable |
| `@total` | Function provably terminates (verified by the path-sensitive prover) | Stable |

Future editions may add new effect annotations (e.g. `@async`, `@noexcept`).
New annotations are **additive**: adding one to a function cannot break callers
that do not inspect it.

Changing an annotation (e.g. removing `@realtime`) is a breaking change to the
function's contract and triggers a new edition if the annotation is removed from
the language.

---

## What Is NOT Stable

The following are internal implementation details. They may change in any
release without notice.

| Artifact | Status |
|----------|--------|
| ZIR format (`selfhost/zir.zag` output) | Internal; no compatibility guarantee |
| `zagc` C-backend output format | Historical oracle; not a stable format |
| `--emit-c` C output from `zagc` | Unstable; do not depend on it |
| AST JSON format (`zag ast`) | Unstable; fields may be renamed or added |
| `zagc` CLI flags | Unstable (oracle, not production) |
| `selfhost/native/isa.zag` `Instr` enum variants | Compiler-internal |
| `ncodegen.zag` internal helpers (`cg_*`) | Compiler-internal |
| `zir.zag` IR node variants | Compiler-internal |
| ELF relocation format in `.o` output | Under development |

---

## Self-Hosting Fixpoint Guarantee

`znc` is required to reproduce itself byte-identically when compiled with
itself:

```sh
./bootstrap.sh                                   # rebuild znc from source
./znc selfhost/native/znc.zag -o znc.new         # znc compiles znc
diff znc znc.new && echo "fixpoint OK"
```

This is the primary regression gate. The fixpoint is verified by
`tests/check_native_bootstrap_repro.sh`. Any change that breaks the fixpoint
is a blocker, regardless of which test suite it appears in.
