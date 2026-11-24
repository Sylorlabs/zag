# PROVENANCE — fix/znc-math-correctness-20261123

Branch: `fix/znc-math-correctness-20261123` on `Sylorlabs/zag`
Fix commit: `356ca6c0e62a583b5f61f800b96432e376f1d1ed`
Seed compiler: `zag-poc/znc` (committed ELF seed, unchanged)
Date: 2026-11-23 (DC-3 session devin-8d33167b54e14286beb0aa27d3fda0a5)

## What this branch fixes (root-caused, DC-C report + fuzzer-discovered)

1. **sar-shift hang (DC-C bug 1)** — `>>` on `u64` emitted arithmetic `sar`
   (fill bit = sign bit), producing non-terminating loops on high-bit
   shifts. Verified fixed in current source: stage-1 emits `shr` for
   unsigned, `sar` for signed.

2. **leq/argv comparison defect (DC-C bug 2)** — three facets:
   - `[]u8`/`[]i8` `==`/`!=` compared slice-BLOCK identity, not content →
     new `__streq` helper (length + bytewise) and ordering via
     `_zag_strcmp_ord` (RT_STRMPO).
   - `*i8`/`*u8` cstring ↔ `[]u8`/`[]i8` slice comparisons had no lowering →
     new `_zag_cstr_slice_cmp` runtime (RT_CSTRSCMP=19, RT_COUNT=20) with
     operand swap + sign flip for slice-left order.
   - `*i8`/`[]i8` element loads were zero-extended → sign-extended via
     `cg_emit_sext_narrow_reg`.

3. **Heap-adjacent corruption (DC-C bug 3)** — root cause: Zag's uniform
   word ABI makes `p[i]` over `*i32` advance 8 bytes/element, so
   `count*sizeof(i32)` allocations silently corrupt adjacent heap. Not a
   miscompile — but now surfaces a non-fatal `cg_note` diagnostic pointing
   at the word-ABI contract.

4. **u64 `/` and `%` (fuzzer-discovered)** — emitted signed `idiv` so
   `0xFFFFFFFFFFFFFFFF / 2` returned 0. Fixed with new `K_DIV`/`i_udiv`
   (xor edx,edx + div), x86 encoder, and disasm kind "udiv".

5. **u64 relational compares (fuzzer-discovered)** — `<`,`<=`,`>`,`>=` on
   unsigned operands emitted signed `jl/jle/jg/jge`. Fixed via
   `cg_cmp_cc_u` dispatching on `cg_is_unsigned_int_type` → CC_B/BE/A/AE.

## Verification

- Bug regression suite: **6/6 PASS** (t1_sar, t2_sliceeq, t3_cstreq,
  t4_i8sext, t5_udiv, t6_wordstride) on the rebuilt stage-1 compiler.
- 100,000+-op randomized 64-bit differential fuzzer (bit-ops, shifts,
  signed/unsigned compares, sparse masks, heap alloc/clone/free patterns)
  vs `gcc -O2` reference: **byte-identical stdout, 0 divergences**.
- `@threadSpawn` aliasing/escape stress (8 workers, disjoint regions of an
  escaped mmap pool): **bad=0**.
- Bootstrap fixpoint (`ZAG_BOOTSTRAP_MEMORY_GUARD=off bash bootstrap.sh`):
  see `FIXPOINT` below.

## FIXPOINT

`ZAG_BOOTSTRAP_MEMORY_GUARD=off bash bootstrap.sh` on `fix/znc-math-correctness-20261123`
@ `356ca6c` (2026-11-24):

- `znc-stage1` (seed compiler rebuilt from fixed source): 10,674,127 bytes
- `znc-stage2` (stage1 self-compile): 10,681,362 bytes
- `znc-stage3` (stage2 self-compile): 10,681,362 bytes
- **stage2 and stage3 are BYTE-IDENTICAL → clean fixpoint reached at stage 3.**
- `zagd` built from `selfhost/zagd_daemon.zag` with the fixed-point compiler (731,884 bytes).
- Emitted only non-fatal `cg_note` word-ABI diagnostics (bug-3 guardrail working as designed).

## FIXPOINT (macos-arm64, ABI-safety branch)

`ZAG_BOOTSTRAP_MEMORY_GUARD=off ZAG_BOOTSTRAP_SEED=<macos-arm64 seed> bash bootstrap.sh`
on `fix/znc-abi-safety-20261124` @ `f345e33` (2026-11-24), Apple Silicon host:

- `znc-stage1` (seed `znc-macos-arm64-01ebe61` rebuilt from patched source):
  14,251,172 bytes text + 616,116 bytes data
- `znc-stage2` (stage1 self-compile): same size
- `znc-stage3` (stage2 self-compile): **BYTE-IDENTICAL to stage-2 → clean
  fixpoint at stage 3.**
- Fixed-point `./znc-macos-arm64` sha256:
  `31e8bd8107a97f8b56aca35ec7fa606c916954a2c6adf9d4e4997101754b05b3`
- `./zagd-macos-arm64` built from `selfhost/zagd_macos_daemon.zag` with the
  fixed-point compiler (435,764 bytes text + 83,461 bytes data).
- Platform note: this record is the macos-arm64 equivalent of the x86-64
  fixpoint above; the two ELF/Mach-O artifacts are not byte-comparable.
