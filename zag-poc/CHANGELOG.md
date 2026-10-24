# Changelog

All notable changes to Zag are documented here. Dates are commit dates in
Pacific Time. Tags are listed in chronological order; all tags preceded
`2026.06.0-dev` — the CalVer scheme begins with the first formal release.

---

## [Unreleased]

### Added
- **AArch64 stack-machine optimizer** (`selfhost/native/aoptimize.zag`), the
  counterpart of the x86-64 `optimize.zag`, wired into `znc_macos_lower_code`
  and into `znc_hot_patch_macos`. The AArch64 backend emitted expression
  temporaries through a stack region around `x28` and nothing ever removed them:
  42.3% of the emitted `__text` was memory operations and the hottest pattern in
  a profile was a pop immediately followed by pushing the same value back. The
  pass removes constant push/pop pairs, folds constant arithmetic, and deletes
  dead moves. **Emitted code is 9–10% smaller and a compute-bound loop runs
  1.36x faster**, with `programs/*` byte-identical in output and exit codes.
  Gated by `make test-aarch64-optimizer`.
  - Not every x86 assumption transferred. The stack pointer is `x28` and is also
    written outside push/pop; float and vector kinds clobber the GPR they name
    because `v0` **is** `x0`; immediates are unsigned imm12 and a negative one is
    unencodable; `AK_AND_IMM` and a wide `AK_CMP_IMM` clobber `x9`/`x10`;
    `AK_MUL_RR`/`AK_SDIV` carry a third GPR in `imm`; and flags cross label
    boundaries, so a label is a breaker.

### Fixed
- **Unsigned 64-bit comparisons, division, modulo, and `print_u64` were lowered as
  signed on both production backends.** A `u64` with bit 63 set compared *below*
  small values, `top / 2` returned a negative quotient, and `print_u64` printed
  `-9223372036854775808`. Comparisons now select the carry-flag condition family
  (`cg_cmp_cc_u` on x86-64, `ac_push_jcc_false_u` on AArch64); `/` and `%` lower
  to `UDIV` on AArch64 and `xor edx,edx; div` on x86-64 when the left operand is
  an unsigned type; and `print_u64`/`print_u32` call a new unsigned decimal
  routine. `emit_udiv` emits `0x9AC00800` — the initial spelling added `0x4000`
  to `SDIV`, which encodes `CRC32X` and printed garbage digits instead of failing
  — and its remainder fixup needs the unsigned `n - q*10`, not `q*10 - n`.
  `K_DIV` is now part of the x86 flag/clobber/liveness model so the peephole and
  DCE passes cannot treat it as side-effect free. A literal magnitude above
  `i64::MAX` (`18446744073709551615`, `0xFFFFFFFFFFFFFFFF`) is u64 by
  construction even when both operands are literals: `18446744073709551615 / 2`
  returned `0` and `% 10` returned `-1` because the pair was typed signed. A
  literal above `i64::MAX` on either operand now selects the unsigned path in
  both native backends. Gated
  by `tests/semantic/unsigned_numeric.zag`, `unsigned_print.zag` (exact stdout),
  and the cross-backend `tests/differential/t59_unsigned_output.zag`.
- **Four release-gate scripts selected the tracked Linux x86-64 seed on ARM
  hosts.** `run_typed_authority.sh`, `run_aarch64_optimizer.sh`,
  `run_vector_pipeline.sh`, and `run_vector_equiv_x86_64.sh` defaulted `ZNC` to
  `./znc`, which cannot execute on Apple Silicon or Linux AArch64; they now use
  the shared `zag_native_compiler` host selector, so the gates also run outside
  `make`, which was previously the only caller exporting `ZNC` for them.
- **A wrong-answer bug in the new AArch64 optimizer's liveness model**, found
  during review before the pass was wired in. `add x0, x1` encodes as
  `add xd, xd, xm`, so the destination is also the first source and `src` is a
  genuine second source. Only the destination was marked live, so a
  rematerialized `mov x1, 5000` in front of the add looked dead, DCE deleted it,
  and the add read an unwritten register. `b = b + 5000` evaluated to `b`, and
  `sort_bench` sorted incorrectly — with no crash and no diagnostic.

### Fixed
- **The macOS `zagd` daemon reallocated the same path five times per file event.**
  Every edit rebuilt the deep-measurement record's path from scratch just to
  unlink it: `zmd_join` is two `_zag_str_concat` calls, and each one allocates
  both a data buffer *and* a 16-byte `{ptr,len}` descriptor through
  `__make_slice`, so a function that reads like "one path string" costs four —
  plus the cstr buffer, five in total. The resource-stress gate counts allocation
  COUNT rather than bytes, which is why this showed up as a steady +5/edit while
  `live_bytes` and `peak_live_bytes` stayed perfectly flat.
  The path is loop-invariant, so it is now built into the caller-owned scratch
  buffers `zmd_execute_deep_controls` already carries. The unlink stays
  unconditional — a stale record from a previous deep run is exactly what light
  mode must clear — so only the rebuilding was removed. **256 edits now allocate
  146 times total, unchanged from the baseline; RSS growth is negative.**
  `make test-zagd-macos-resource-stress` passes, as does
  `test-zagd-background-semantics`, which was blocked behind it.
- **`tests/run_reference_dynamic_plugin_macos.sh` could not be driven with a
  wrapper compiler.** The macOS release gate passes a compiler wrapper that
  resolves the real compiler *relative to its own `argv[0]`*. The test staged
  `znc` but not `znc-real`, so relocating the symlink made the wrapper exit 127.
  It now stages `znc-real` too, matching `run_macos_zagscript_authority.sh`.

### Changed
- **Compiler self-compile is 1.19x faster**, byte-identical output. Two changes,
  both pure optimizations:
  - **Mach-O output and SHA-256 no longer copy byte at a time.** The image
    writers appended through `push[u8]`, one out-of-line call per output byte,
    and `macho_sha256` built its padded message block the same way. They now
    reserve once and `_zag_memcpy` once. `sh_constants()` and the 64-entry
    message schedule were also allocated *per block* — about 236,000
    allocations and 30M pushes for a 15 MB image — and are now hoisted.
    Compiles whose cost is dominated by output size are 4.7–6.1x faster
    (a 4 MB data segment: 17.5 s → 3.7 s).
  - `sh_ror` built a 32-bit rotate from two loops totalling 32 iterations plus a
    64-bit divide and remainder — measured at 181 ns per call against a few
    cycles for the shift-and-or it now compiles to. SHA-256 calls it 384 times
    per 64 bytes.
- **The compiler-image read and hash are skipped when the foreground cache
  cannot use them.** The 15 MB image was read and hashed on every build, and the
  result feeds exactly one thing: the cache key, inside the branch that only runs
  when the cache is eligible. Eligibility's cache-independent half is now
  decided first. This path previously also read the image while
  `--no-foreground-cache` was set, i.e. precisely when the result was discarded.
- **Rejected: an arity index for the call-arity check.** Replacing the per-call
  rescan of the declaration list with a name→arity hash map measured as
  **neutral** — 247.7 s to 247.6 s on the self-compile, inside noise, so the
  rescan is evidently short-circuited for nearly every callee. It then
  **segfaulted** the compiler on `--safety=checked` programs, because it was the
  first thing to import `selfhost/std/hashmap.zag`, which nothing had ever
  compiled: wiring up never-exercised code surfaced latent defects in it. Reverted
  — the binary is byte-identical to before the attempt. The lesson is recorded
  rather than the code: dead code is not free to adopt, and a plausible-sounding
  complexity argument is not a measurement.

### Fixed
- **`_zag_memcpy` was unusable in a `--target macos-arm64` program.** The AArch64
  backend lowers a call to it and sets `use_mc`, but `ac_emit_memcpy` was only
  reachable from `aload_program_target_metadata`, so on the macOS path the call
  targeted a label that was never emitted and jumped to garbage — a `SIGSEGV`.
  Nothing on that path called `_zag_memcpy` before, so the gap was latent; the
  bulk-copy change above is what first reached it. Any macOS-arm64 program using
  `_zag_memcpy` or `_zag_memcmp` would have crashed.
- **`zvec_ty_valid` counted elements where the ceiling is in 32-bit units.** The
  width ladder is expressed in 32-bit-equivalent lanes, but this check passed the
  raw element count, so `vector<i64,16>` (256 bytes, two registers) validated as
  a single-register type. It now converts exactly as `vectorize.zag` and
  `ncodegen.zag` do.
- **The ZIR-to-C printer could read past the end of an operand list.** Its
  fallback branch indexed `operands[1]` and `results[0]` unconditionally, which
  is out of bounds for every `vector.*` op (one operand, no result) — reachable
  only once the vector pipeline began emitting them. It now checks arity and
  prints an explicit "not representable in C" note. Relatedly, `c_type` returned
  `int32_t` for any unrecognized type, misstating the `memref<vector<ELEM,N>>`
  accumulator slot as a scalar; it now names the type instead.
- **`tests/run_v2_try_borrow.sh` and the macOS release gate required ripgrep**
  without declaring it, failing with `rg: command not found`.

### Added
- **Declared x86-64 microarchitecture levels** — `--cpu=x86-64-v2`, `-v3`, and
  `-v4` name a level instead of detecting one, which is what makes the 256- and
  512-bit vector rungs buildable and testable on a host that lacks the hardware.
  `v3` selects the AVX2 rung (4 lanes, `ymm`) and `v4` the AVX-512 rung (8
  lanes, `zmm`); `v2` adds SSE4.2/POPCNT without changing vector width. Each
  level has a distinct `cache_key`, so artifacts built for different levels can
  never be served for one another. Carrying the runtime profile's value of `2`
  for the AVX bits widens the vector pipeline without also enabling the bounded
  scalar `i32x4` path. Measured on a 90M-element reduction, speedup tracks lane
  count: **2.37x** at 2 lanes, **4.22x** at 4. See `docs/VECTOR_PIPELINE.md`.
- **Vector pipeline** — a target-independent vector IR, an opt-in auto-vectorizer,
  a vector register allocator, and CPU-width lowering, layered so no layer can
  guess at another's decision. `selfhost/vector_contract.zag` is the single
  source of truth for the `vector<ELEM,LANES>` spelling, the op set, the
  width-class ladder, and the target lane ceilings.
  - **Vector IR** (`selfhost/zir_vector.zag`): `vector.splat`,
    `vector.broadcast`, `vector.extract`, `vector.insert`, `vector.add/sub/mul`,
    `vector.bit_and/bit_or/bit_xor`, `vector.shl/shr`, `vector.icmp`,
    `vector.select`, `vector.reduction_add`, `vector.shuffle`; an 11-fault-class
    verifier wired additively into the existing def-before-use sweep, a
    fixpoint vector-aware DCE that never removes a memory-reading op, an MLIR
    printer, and module statistics.
  - **Auto-vectorizer** (`selfhost/vectorize.zag`): natural-loop analysis,
    induction-variable detection, and an alias/dependency proof with twelve
    documented reject codes. The sound design is a memory-resident induction
    variable, so the pass inserts a *vector main loop* guarded by
    `i + LANES <= n` and leaves the original scalar loop untouched as the
    epilogue — no phi, no peeling, any trip count. A floating-point accumulator
    is refused because wrapping integer addition is associative and float
    addition is not.
  - **CPU-width lowering** (`selfhost/native/vecwidth.zag`): realizes the ladder
    in 32-bit-equivalent units, splitting a wider logical vector into
    independent per-piece operations with distinct virtual registers, and failing
    closed rather than emitting an unencodable form. The ladder is
    stride-derived: an element is a whole 8-byte word, so the target ceilings of
    16/8/4 units are 8/4/**2** elements, and 2 `*i32` lanes is what the generic
    128-bit baseline actually carries.
  - **Vector register allocation** (`selfhost/native/vregalloc.zag`): a real
    backward liveness pass, live intervals, and linear scan over a pool that
    starts above whatever the scalar float lowering and existing SIMD scratch
    already use. An unrecognised instruction kind clobbers every vector
    register; the pass never spills, and refuses instead.
  - **Machine encoders**: a generalized VEX emitter, a full EVEX emitter for
    512-bit, scaled-index SIB forms, and width-parameteric packed ops on x86; on
    AArch64 a packed width/element descriptor replaces the hardcoded `.4S` plus
    23 new Advanced SIMD opcodes including `bsl`/`bit` select and `ld1`/`st1`
    element-scaled addressing.
  - **AVX-512 feature detection** (`x86_cpu_profile.zag`): AVX512F
    (CPUID.7.0:ECX bit 16) *and* the opmask/ZMM state components (XCR0 bits
    5,6,7). Both halves are required; either alone can `#UD`. This is what
    makes the 16-lane rung reachable rather than aspirational.
  - **`--vectorize=off|on`** (default `off`). The request selects whether the
    pass runs; the CPU profile alone selects the width. Both the request and the
    resolved rung are part of the foreground cache key. The vectorized module is
    re-verified after the pass and discarded in favour of the scalar module on
    any fault.
  - **Machine lowering**: `zag.index` indexed element reads, vector SSA values
    living in virtual vector registers, and real SSE2/AVX2/AVX-512 emission —
    a word broadcast, a vector load scaled by the element's **address stride**,
    the elementwise op, and a horizontal fold of one shuffle plus one add plus
    one 64-bit extraction per 128-bit chunk. The emitted bytes are verified
    against LLVM's disassembler.
  - **Runtime proof on x86-64** (`tests/run_vector_equiv_x86_64.sh`, part of
    `make test-vector-pipeline`): a vectorized and a scalar build of a
    self-checking equivalence program are both *executed* and must each agree
    with their own scalar reference across 18 trip counts. This is the only
    check in the suite that proves the emitted code computes anything, and it is
    the check that found the five lowering bugs under **Fixed** below. It skips
    rather than fails where no amd64 emulator is available.
  - `docs/VECTOR_PIPELINE.md`, `make test-vector-pipeline` (IR, vectorizer,
    epilogue preservation, machine lowering, off-by-default boundary,
    runtime equivalence).

- **Native Apple-Silicon dynamic libraries and custom linking** — strict
  edition-2027 scalar/bounded-`f32`/`f64` plus bounded flat/nested 64-bit-leaf
  and flat small integer/bool/pointer struct import/export and direct-callback
  C-ABI `--emit-dylib`/`--emit-shared`, custom `--dynamic`
  executables, `-l`/`-L`/`--needed`, bounded TAPI-v4 SDK-library and `-framework`/`-F` lookup, source/manifest dependencies, install names
  and runtime paths now use a Zag-owned linker and deterministic signer.
  Native CLI and format suites cover checked C/Zag/C calls, independent
  Darwin FP/X-register `f32`/`f64` imports and exports with explicit f32 single/double conversion, direct scalar callbacks, and bounded
  f32/f64 callbacks through explicit `pub @cabi_export` callback targets,
  including closed libSystem `cosf`/`powf`/`ldexpf` execution without a host linker,
  plus ten-FP-argument import/export/callback witnesses covering V0-V7 and
  Darwin's naturally packed stack overflow, plus ordinary 64-bit-leaf struct
  imports/exports covering flat/nested small INTEGER register/stack transport
  and flat/nested large caller-copy/`X8` indirect results, plus an explicit
  pack/unpack adapter for flat naturally aligned integer/bool/raw-pointer
  structs whose Darwin C layout is at most 16 bytes (including subword fields,
  padding, one/two-register transport, and whole-value stack spill),
  real CoreFoundation framework lookup plus target-scoped `.tbd` validation, relocated trees,
  versioned symlinks, 305 exports, pointer rebase/bind, universal dependencies
  and malformed inputs. They are required by the full source-qualified Mac
  gate; this does not add a general C ABI, Intel Mac support or whole-target
  Linux parity.
- **Native Apple-Silicon static object/archive input linking** — explicit ARM64
  Mach-O `.o` and BSD `.a` inputs now merge into Zag-owned dylib and custom
  executable output through positional operands or `--static-input`. The native
  gate covers deterministic CLI forms, bounded/symlinked inputs, selective and
  transitive archive extraction, COMMON plus strong/weak resolution,
  private-external visibility, absolute/page/GOT/`POINTER_TO_GOT` relocations,
  resolved and missing weak imports with dyld null fallback, imported TLVP loads
  through dylib-exported thread-local symbols, same/cross-output-section
  subtractors, and static/dynamic composition. Static TLS-defining object
  sections, authenticated ARM64e pointers, and arbitrary foreign-object formats
  remain fail-closed.
- **Reviewable clean-checkout Apple-Silicon bootstrap** — the physical-Mac CI
  gate now publishes its actual fixed-point compiler only after the complete
  native gate passes, under a name distinct from the Linux cross-built
  precursor and alongside a logged SHA-256 plus source commit. The explicit
  `tools/bootstrap-macos-seed.sh` intake verifies checksum, signed Mach-O host
  identity, a source-built fixed point, and the independent empty-`PATH`
  reproducibility proof before building checkout-qualified compiler, daemon,
  and LSP artifacts; it never downloads or auto-selects trust.
  Native release archives also carry `znc.sha256` for a durable intake route
  after verification of the signed tag and outer archive checksum.
- **Reproducible VS Code packaging** — the extension now has a committed npm
  lockfile, pinned `vsce`/bundler dependencies, a working `npm run package`, a
  bundled runtime client, and fixed ZIP timestamps. CI and `release.sh` require
  repeated packages to be byte-identical, and release archives ship both the
  ready VSIX and the locked source package without transient build trees.
- **V2 unsafe/raw-pointer vertical slice** — edition-2027 now has a dedicated
  unsafe-block AST node, direct `unsafe fn` declarations/call-site checks, and
  `Unsafe` effect propagation into `@pure` and `@realtime`. Qualified pointer
  categories reach native lowering, and shared semantic checks reject
  safe-scope dereference, `*const` mutation, opaque dereference, raw-pointer
  arithmetic outside unsafe, and ordinary type errors inside unsafe. Native
  execution and AArch64/WASM/GPU lowering regressions cover the boundary; the
  programs gate now retains actual exit status. Indirect calls, provenance,
  alignment instrumentation, and the complete unsafe-operation inventory
  remain incomplete.
- **V2 raw-pointer nullability and address-space separation** — nullable raw
  pointers must be explicitly unwrapped before dereference, with a native
  execution regression for the valid path. Direct casts between generic,
  host, device, and workgroup pointer spaces now fail before lowering and leave
  no artifact. Provenance identity, bounds, aliasing, lifetime, and alignment
  instrumentation remain incomplete.
- **Shared declared-type authority** (`selfhost/typed.zag`) — native x86-64,
  AArch64, WASM, GPU MLIR, and restricted gfx1010 builds now reject unknown
  signature, generic-argument, cast, struct-literal, and explicit-local types
  before backend lowering. The new E0202 path leaves no target artifact and is
  exercised by `tests/run_typed_authority.sh`. Conservative shared expression
  typing also rejects wrong-category returns, call arguments, assignments, and
  arithmetic with E0203 while preserving existing numeric/generic extensions.
  Backend IR unification and complete expression typing remain incomplete.
- **Exact GPU IP/ring certification tuples** (`std/gpu.zag`) — certification
  identity now includes both kernel HW-IP versions and IP-discovery revisions,
  plus the available GFX and compute ring masks. A discovery revision or ring
  topology change invalidates promotion instead of hiding behind an unchanged
  device ID and firmware pair.
- **Non-promotable virtual GPU certification** (`std/gpu.zag`) — a distinct
  evidence type enforces compiler manifests, ownership/fences, 10,000 fills,
  10,000 transfers, one million submissions, 86,400 logical soak ticks, raster
  differentials, and zero anomalies. Its success code is explicitly virtual and
  the type cannot be passed to physical automatic-promotion policy.
- **User-selectable GPU backends** (`std/gpu.zag`) — applications can expose
  `auto`, `cpu`, `virtual`, and `physical` without a language-mandated mode.
  Auto chooses certified isolated hardware when available, otherwise the strict
  virtual GPU or CPU; explicit physical selection retains the acknowledgement
  boundary instead of disappearing behind the default.
- **Named GFX10.1 instruction encoders** — the restricted native GPU backend
  constructs its reviewed fill program from checked operand fields instead of
  opaque whole-instruction literals. Out-of-range VGPR/SGPR/immediate fields
  fail closed, the semantic decoder derives the same sequence, and the emitted
  ZGK1 bundle remains byte-for-byte stable.
- **Fail-closed Linux GPU isolation discovery**
  (`std/linux_gpu_isolation.zag`) — distinguishes shared GPUVM/process-cleaner
  and partition-control configurations from a probed SR-IOV VF with its own
  IOMMU group and FLR reset support. Only the latter authorizes destructive GPU
  testing. Includes fixture regressions and a live sysfs reporting example.
- **Strict virtual GFX10.1 command processor** (`std/gfx1010_vm.zag`) — loads
  compiler-owned ZGK1 bundles, decodes the complete supported instruction
  sequence and PM4 register stream, verifies resource metadata, reserved bits,
  and virtual addresses, then executes against bounded virtual GPU memory.
  Unknown packets/registers and out-of-bounds dispatches fail closed without
  opening DRM, enabling display-safe end-to-end compiler/runtime testing. Its
  queue model enforces explicit CPU/device ownership, monotonic fences, memory
  barriers, and permanent anomaly quarantine.
- **Compiler-owned `std:` imports** — `@import("std:gfx1010_vm")` resolves from
  the standard library shipped beside/with `znc`, cannot be shadowed by a
  project's local `std/`, and rejects traversal syntax. `make install` now
  installs the pure-Zag standard library alongside the self-hosted compiler.
- **`continue` control flow** — the lexer, parser, AST, semantic walk, generic
  cloning, and both native backends now support `continue;` with the correct
  innermost-loop target. Nested-loop regressions run on x86-64 and AArch64.
- **Static analyzer** (`selfhost/analyze.zag`) — a second analysis pass that runs
  by default on every `znc` build/check, printing warnings to stderr:
  - **Memory-leak detection**: `L0001` (a value from a manual allocator —
    `zalloc`/`zalloc_i`/`_zag_malloc`/`_zag_realloc`/`@cacheAlignedAlloc` — that
    is never freed, returned, aliased, or passed on) and `L0002` (an allocation
    whose result is discarded immediately). Conservative: any ownership transfer
    counts as "handled", so correct code is never flagged.
  - **Algebraic-efficiency lints**: `E0101` identities (`x+0`, `x-0`, `x*1`,
    `x/1`), `E0102` always-constant (`x*0`, `x-x`), and `E0103` strength
    reduction (`× 2ᵏ` → shift) under `--analyze-pedantic`.
  - Flags: on by default; `--no-analyze` silences; `--analyze-strict` fails the
    build on findings; `--analyze-pedantic` enables `E0103`. Analysis never
    changes the emitted binary (self-hosting fixpoint unaffected).
  - Tests: `tests/run_analyzer.sh` / `make test-analyzer`.
- **Native live code hot-reload** (`selfhost/native/hot_rt.zag` + `znc hot-patch`)
  — swap a running program's machine code without restarting; in-memory state
  survives. Build with `znc build --hot <src>`, drive the loop with
  `zag_hot_should_continue()` / `zag_hot_wait()`, then after a layout-preserving
  edit run `znc hot-patch <src>`; the process memcpy's the re-assembled `.text`
  over its live code in place (guarded so a size-changing edit asks for a rebuild
  instead of corrupting the process). Pure-Zag runtime, raw syscalls only, no
  codegen changes. Demo: `examples/hot_demo.zag`. Tests: `tests/run_hot_reload.sh`
  / `make test-hot-reload`.

### Fixed
- **Exact-width byte memory operations** — x86 native codegen now emits real
  `movzx` byte loads and byte stores. The former 8-byte masked load/store
  workaround could cross an mmap boundary at the final byte and intermittently
  crash `znc`; a guard-page regression now proves both reads and writes remain
  within the addressed byte.
- **Native stack-frame high-water hardening** — function lowering now patches
  each prologue from the authoritative number of slots actually allocated while
  lowering. The pre-scan remains a sizing optimization, but an omitted scratch
  or capture case can no longer under-reserve the frame and corrupt the stack.
- **Vector lowering read and computed the wrong values.** Eight defects, all of
  which passed every IR, byte-decoding and shape assertion in the suite because
  the emitted machine code was well-formed in every one of them. They were found
  only by *executing* a vectorized program on x86-64, which is why
  `tests/run_vector_equiv_x86_64.sh` now exists:
  - **The vector load was scaled by the element WIDTH, not its address
    STRIDE.** Native layout gives every non-byte scalar a full 8-byte word, so
    `p[i]` over a `*i32` advances eight bytes; a load scaled by 4 gathered four
    bytes-packed words, none of which are adjacent array elements. The loop read
    the wrong data and still decoded perfectly. Lanes are now derived from the
    stride (`zvec_elem_stride`), which also makes the correct lane count per
    width 2/4/8 rather than 4/8/16.
  - **The horizontal fold added the scratch to itself**, doubling one partial
    sum (`2q`) instead of totalling the vector (`p+q`). A shuffle tree needs the
    un-permuted partials in one register and their permutation in another; with
    one scratch that is not expressible. Replaced with `vpshufd $0x4E` (which
    swaps the two 64-bit halves of each 128-bit chunk) plus one `vpaddq` plus
    one 64-bit extraction per chunk.
  - **The 64-bit extract fold loaded each lane into the accumulator before
    adding the pending one**, dropping every other lane and leaving the last
    pair as the whole sum.
  - **A fold left stale high-half garbage in the GPR** (`vpextrd` writes 32
    bits) while i32 comparisons lower to a 64-bit `cmpq`, so a correct reduction
    failed its own `==`.
  - **A broadcast accumulator was summed once per lane** by the horizontal fold,
    making the second and later vector iterations compute `L*acc + sum(e)`. The
    vectorizer now splats zero and the `reduce = "add"` store accumulates into
    the scalar slot once per iteration.
  - Also in the same path: the scaled-index load hardcoded REX.X, so every
    index register was read 8 higher (`index=2` encoded as `r10`); and
    `zag.index` used `i_imul(idx, idx)`, addressing `a + n*n` in the scalar
    epilogue that has to stay equivalent to the original loop.
  - The vector accumulator slot was reserved at **one** 8-byte frame word. A
    vector slot is a whole 16/32/64-byte register, so the value after it landed
    inside it: the loop's step constant was overwritten with the slot's low
    bytes, the step became zero, and the loop never terminated. The size test
    missed it because a vector slot's type is `memref<vector<ELEM,N>>`, which is
    not itself a vector type.
- **The vector loop's epilogue was silently dropped from the diagnostic output.**
  A module that the ZIR-direct route refuses fell back to the AST bridge with no
  indication, so a vectorized program could be built, run, timed, and reported as
  "vectorized" while every vector instruction had been discarded. The lowering
  line now names the refusing op (`refusal=<op>`), which is also what caught a
  benchmark whose single `&` in `main` kept the whole module out of the direct
  subset — so the first "no speedup" measurement was measuring scalar code.

### Removed
- **Non-Zag WASM execution oracles** — removed the Rust/Cargo Wasmtime host,
  JavaScript/Node fallback, and compiler `--run` shell-out. WASM emission stays
  pure Zag; execution now fails closed with `E0800` until a pure-Zag runtime is
  implemented.

---

## [2026.06.0] — 2026-06-30

First formal CalVer release. `./znc` is the sole supported compiler: native
x86-64 ELF, GPU MLIR (`--target gpu-*`), WebAssembly (`--target wasm`), and
in-process `@total` SMT proofs — all from one seed binary.

### Added
- **GPU MLIR and WASM on `./znc`**: lean `mlir.zag` (no `codegen.zag` import)
  and `wasm.zag` merged into `znc.zag`; single `./bootstrap.sh` fixpoint.
- **In-process SMT solver** (`smt_solve.zag`): QF_LIA/QF_NIA discharge for
  `@total` without shelling out to external tools on the normal path.
- **WASM tagged-union/enum switch** lowering (`examples/wasm_op.zag`).
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

### Fixed (native backend gaps, see `programs/GAPS.md`)
- Union scalar capture `|v| v` binds payload values, not pointers.
- Forward function declarations (`fn foo() T;`) parse without SIGSEGV.
- `@pure` / `@noalloc` enforced for `_zag_malloc`, `_zag_println`, and peers.
- Nested `ArrayList[ArrayList[T]]` monomorphization (one level deep).
- `print_str` accepts `*[]u8` union-arm captures.
- `i32`/`u32` arithmetic truncates to 32 bits on store and widen.

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
