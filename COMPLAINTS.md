# Zag complaint sweep — agent/zag-complaints-20261121

Host: Apple M5 (Darwin 25.6.0 arm64), shared machine, all heavy runs `nice -n 12`.
Compiler under test: `./znc-macos-arm64` bootstrapped to byte-identical
fixpoint from this worktree's sources (seed: prior native-gate
`znc-macos-arm64` — see C-011 note on the `--` artifact).

Classification: REAL-BUG (fixed) / PLATFORM-ARTIFACT / STALE-DOC / NOT-A-BUG.

## Live complaints

### C-001 — `tools/bootstrap-macos-seed.sh` missing from tree — REAL-BUG — FIXED 09fa0c0
Evidence: `docs/SUPPORT.md:183` + `tests/run_docs_truth.sh:66` promise the
helper; `tests/run_macos_arm64_release.sh:660` invokes it in `--verify-only`
mode; `bootstrap.sh` names it for clean-checkout seed intake. File absent
from the committed tree (`git log HEAD -- <path>` empty).
Fix: restored from commit `390f750` (byte-identical to the sibling agent's
in-flight copy). Commit `09fa0c0`.

### C-002 — `tools/package-release.sh` missing from tree — REAL-BUG — FIXED 09fa0c0
Evidence: `release.sh:259` delegates to it; `docs/MACOS_NATIVE_PARITY.md:198`
and `RELEASES.md:211` document it; `tests/check_release_package.sh:88` and
`tests/run_release_package_roundtrip.sh` execute it. Absent from tree.
Fix: restored (390f750 + zag.mod toolchain-identity pin check, matching the
sibling agent's in-flight version; `zag_verify_manifest_toolchain` exists in
`tests/portable.sh`). Commit `09fa0c0`.

### C-003 — `tests/run_script_interpolation_project.sh` missing — REAL-BUG — FIXED 1eeed3a
Evidence: `tests/run_zagscript_release_gate.sh:389` and
`tests/run_macos_zagscript_authority.sh:404` gate on it
(`run_gate 'typed interpolation and map projection' ...`); absent → exit 127.
Fix: restored the wrapper from `ce26f57` (composes the existing
run_script_interpolation_parser / run_script_interpolation /
run_script_projection suites). Commit `1eeed3a`.

### C-004 — `tests/fixtures/macos_dylib_loader.c` missing — REAL-BUG — FIXED 5ddd054
Evidence: `tests/run_macos_dylib_format.sh:23` compiles it with
`xcrun clang` as the dlopen/dlsym oracle; `check_pure_zag_tree.sh:13`
whitelists it as one of only two permitted C files, so tree policy expects
it present; file absent → test fails at compile.
Fix: restored from `75e2630` (byte-identical to sibling's copy). Commit `5ddd054`.

### C-005 — stale log `zagscript-gap-audit-latest.log` shows zir-authority /
dynamic-ABI failures — PLATFORM-ARTIFACT — CLOSED
Evidence: Sep-13 log ran `run_zir_authority.sh` + `run_dynamic_abi.sh` on
macOS; both emit/execute ELF x86-64 artifacts → "cannot execute binary
file" × 20 (zir) and 18 XX (dynamic ABI). These suites are Linux-x86-64
execution-bound by design.
Current state: `tests/run_zagscript_gap_audit.sh:55-75` already gates
Darwin:arm64 to `run_zagscript_views.sh`, `run_macos_dylib.sh`,
`run_macos_object.sh`, `run_reference_dynamic_plugin_macos.sh` and
`run_zir_authority_portable.sh` provides the Darwin zir path. The
sibling's own `zagscript-gap-audit-macos-fixed.log` shows pass=13 fail=0.
Residual: neither `run_zir_authority.sh` nor `run_dynamic_abi.sh`
self-gates when invoked directly on Darwin — they fail with confusing
binary errors instead of an explicit skip. See C-006.

### C-006 — `run_zir_authority.sh` / `run_dynamic_abi.sh` do not self-gate
on non-Linux hosts — PLATFORM-ARTIFACT — FIXED b7b5fa2
Evidence: `run_zir_authority.sh` uses `${ZNC:-./znc}` and executes emitted
ELF artifacts; `run_dynamic_abi.sh` needs `readelf`/ELF SONAME execution.
On Darwin they produce "cannot execute binary file" cascades (the stale
log's exact symptom). Every gate that calls them is platform-gated already,
but a direct invocation on macOS mis-reports platform as product failure.
Fix: added explicit host guards that exit 2 with an
"unsupported host" diagnostic (matching run_macos_arm64_release.sh's
existing convention), commit `b7b5fa2`. Verified on Darwin: both now exit 2
with a clear message instead of "cannot execute binary file" cascades.

### C-007 — `run_native_lint.sh` fails 6 pedantic checks with sibling seed —
PLATFORM-ARTIFACT — VERIFIED POST-BOOTSTRAP
Evidence: `check_code file CODE -- --analyze-pedantic` forwards a literal
`--` argv entry to znc. The sibling agent's in-flight znc (used as the
pre-bootstrap seed) runs new strict option validation
(`znc_validate_options`, "W1b: fail closed on unknown options") which
rejects `--`. My branch's committed sources contain no such validator, so
the compiled znc ignores `--` (POSIX end-of-options) and the checks pass.
Verified with the fixpoint `znc-macos-arm64`: `znc f.zag -o out -- --analyze-pedantic`
and `znc f.zag -o out --analyze-pedantic --` both compile+run cleanly — `--`
is accepted in either position.
Sibling heads-up: their `znc_known_option` does not whitelist `--`; if the
POSIX marker should remain legal, they may want to accept it.

### C-008 — `tests/run_optimize.sh` dead test (requires retired `./zagc`) —
STALE-DOC — FIXED 0701e2a
Evidence: script builds `selfhost/native/znc.zag` via `./zagc build`, but
`check_pure_zag_tree.sh` forbids `zagc`/`selfhost/zagc*` entirely and no
zagc exists in the tree. Nothing references run_optimize.sh (superseded by
`tests/run_optimize_preview.sh`, used by `run_zagscript_release_gate.sh:458`).
Last touched by b5455c4 (Phase D). Can never run on any platform.
Fix: removed the dead suite (`git rm`), commit `0701e2a`.

### C-009 — `programs/GAPS.md` Gap-4 repro uses retired bare `ArrayList` —
STALE-DOC — FIXED 08cb753
Evidence: repro declares `ArrayList[ArrayList[i32]]` unqualified; since the
std: module namespacing, bare `ArrayList` is internal-only and the repro
now fails with `error[E0202]: unknown type 'ArrayList'` (a clean diagnostic,
not the original codegen crash). Re-running the equivalent program with
`@import("std:list")` compiles and runs correctly — the June fix holds.
Fix: verification note added under the Gap-4 repro, commit `08cb753`.

### C-010 — programs/GAPS.md verification results — NOT-A-BUG (all 8 hold)
Re-run on macOS arm64 (fixpoint compiler):
- Gap 1 union-arm capture: prints 42 (was: garbage pointer deref) — holds
- Gap 2 fwd-decl SIGSEGV: compiles+runs, mutual recursion prints 42 — holds
- Gap 3 @pure/@noalloc on _zag_*: now rejected `error[E0002] capability
  violation` — holds
- Gap 4 nested generics: compiles+runs with `std:list` — holds (see C-009)
- Gap 5 print_str(union capture): prints "world" — holds
- Gap 6 i32 truncation: 920370032 both via i32 and i64 cast — holds
- Gap 7 @alloc annotation: accepted — holds
- Gap 8 generic structs: instantiate+run — holds

### C-011 — test/audit suite re-run on macOS arm64 — CLOSED (complete)
Method: `ZAG_BOOTSTRAP_MEMORY_GUARD=off nice -n 12 bash bootstrap.sh` to
fixpoint (load-gated), then every macOS-applicable suite.
Doc gates already run: `run_docs_truth.sh` PASS (fail=0),
`run_docs_consistency.sh` PASS (14/14), `check_pure_zag_tree.sh` PASS.
Bootstrap log `/tmp/zag-bootstrap-run.log`: `znc-macos-arm64` reached a
byte-identical fixpoint at stage 3; `zagd-macos-arm64` built from the
fixed-point compiler.
Final outcome: fresh 55-target `DEFAULT_TEST_TARGETS` Darwin-arm64 run
on the final fixpoint — 54 PASS + C-024 transient (serial-verified).
`test-macos-arm64-release` passed 69/0 twice (standalone + in-matrix).

### C-012 — `run_vector_equiv_x86_64.sh` fails x86-64-v1/v2 under Docker on
Apple Silicon — PLATFORM-ARTIFACT — FIXED 8ee1011
Evidence: the `vectorize=on` build exited 3 (the `check(base,3)` call) while
`vectorize=off` exited 0. Investigation of the emitted `vec_sum` found no
codegen defect:
- the IR and machine code zero-initialise the slot-carried vector
  accumulator (`vpxor xmm15` + `vmovdqu` store to `[rbp-72]`) before the loop;
- `zir_native_collect_block_slots` sizes vector memref slots at full width
  (16B at SSE2), frame=232, regalloc spill slots at -240/-248/-256 — no slot
  overlaps the accumulator range `[-72,-57]`;
- every emitted VEX byte sequence was re-encoded and verified;
- a hand-encoded compiler-free replica of the exact instruction pattern
  reproduced the same stale-accumulator behaviour under the same executor;
- **decisive control**: the identical failing binary exits 0 under
  `qemu-x86_64 -B 0x100000000` (apk qemu-x86_64 9.0.2 inside the same
  alpine container), and a 296-byte minimal probe of the pattern
  (scalar-init a frame vector slot; loop { load, add, store }; fold)
  exits 1 under Docker's direct amd64 translation but 0 under qemu.
Conclusion: Docker Desktop's amd64 translator on this host misexecutes
loop-invariant VEX loads (hoists them above aliasing stores or reuses stale
register contents); the generated code is byte-correct x86-64. Not a
compiler bug.
Fix: `tests/run_vector_equiv_x86_64.sh` now embeds the 296-byte executor
fidelity probe. When the probe fails, vectorized-run disagreement degrades
to BUILD-ONLY (identical policy to a missing ISA); scalar-build disagreement
still fails since the `vectorize=off` build contains no VEX ops. Commit
`8ee1011`. Matrix row after fix: `vectorize=on` v1/v2 BUILD-ONLY, v3/v4
BUILD-ONLY (#UD), all four `vectorize=off` PASS.

### C-013 — `run_script_allocation_accounting.sh` asserts stale process
capture charge — REAL-BUG (test) — FIXED 08db0b0
Evidence: `make test-script-allocation-accounting` exits 3 — `process_ok`
returns 3 because `script_alloc_used()` is 1048504, not the asserted
1048520. Charge breakdown verified live on the fixpoint compiler:
pair(8)+cmd bridge(15)+argv(32)+envp(8)+buffer(1048401)+statusp(8)+32-byte
script result handle = 1048504. The default Script allocator resolves to
`script_process_arena` (policy 1), under which the result handle is charged
at its 32-byte public size; 1048520 would require `script_bounded_heap`
(policy 2, 48-byte charge). The compiler/runtime behaviour is correct —
the expectation was stale.
Fix: cherry-picked upstream `4f8f440` ("test(zagscript): assert actual
process capture allocation charge") which had already made exactly this
correction — "Verified identical on native macOS-arm64 and linux-x86_64" —
but never reached this base. Cherry-pick commit `08db0b0`. Post-fix:
`bash tests/run_script_allocation_accounting.sh` prints
`script allocation accounting: PASS`, rc=0.

### C-014 — install recipe omits `process_platform.zag` — REAL-BUG — FIXED 4b8b2fd
Evidence: `make test-zagscript-install-layout` exits 1 at the staged
`all-prelude.zag` compile with
`zag: error: @import cannot read '<prefix>/lib/zag/std/process_platform.zag'`.
`selfhost/std/process.zag:8` does `@import("process_platform.zag")`, but the
`install` recipe copied only `process.zag`, so an installed compiler cannot
resolve the Script process module and any program calling
`process_run_timeout` fails. `process_platform.zag` is a leaf (no imports);
no other installed selfhost/std module has unmet transitive imports
(audited all 12 installed script_* files — only process.zag imports a
selfhost/std sibling).
Fix: added `selfhost/std/process_platform.zag` to the Makefile install
recipe and to `run_zagscript_install_layout.sh`'s required-file list.
Commit `4b8b2fd`. Verified end-to-end: `make test-zagscript-install-layout`
passes — "Zag Script staged install layout: pass (production recipe,
native compiler/daemon/LSP, installed std)".

### C-015 — `test-zagd-product` failed once under concurrent load —
PLATFORM-ARTIFACT (load contention) — CLOSED
Evidence: matrix run at 04:07:57 exited 2 while a parallel fixpoint
bootstrap (the C-014 verification re-run) was executing — the zagd
lock/daemon lifecycle suite is timing-sensitive. Two direct serial
re-runs of `tests/run_zagd_product.sh` each printed `zagd product: pass`
rc=0 (console output, same session — not tee'd to a retained file).
No product defect.

### C-016 — `test-macos-arm64-release` dies at C-oracle link: host SDK/ld
mismatch — PLATFORM-ARTIFACT — FIXED b6bd973
Evidence: the release gate reached the `run_macos_object.sh` caller-link
step and `xcrun clang` failed with
`ld: tapi error: malformed file ... libSystem.B.tbd: unknown architecture
arm64e.x1` — the default `MacOSX27.0.sdk` ships tbd entries the installed
ld-1267 cannot parse. Zag's own emission was uninvolved (Mach-O
objects/archives were written and verified before the C oracle step).
Fix: `zag_select_macos_sdk` in `tests/portable.sh` probes by linking a
trivial program — default SDK first, then every installed SDK — and
exports `SDKROOT` for the first that links; all six clang-using macOS
suites call it and exit 2 when no SDK works. Commit `b6bd973`. Verified:
`run_macos_object_encoder.sh` selects `MacOSX.sdk` and passes.

### C-017 — `repr_c_xbutton_event.zag` fixture violates the linear
resource contract — REAL-BUG (fixture) — FIXED 8384c6c
Evidence: after C-016, the release gate reached `run_repr_c_layout.sh`
and failed `XButtonEvent @repr(C) compiles` with 38 E0204 diagnostics —
`resource read/write is unavailable after move or release` (every `raw`
access after the cast) and `resource owned by 'event' is neither released,
moved, nor returned`. The fixture allocated `raw` in `main`, cast it into
`event`, and returned early from each layout check, so the checker cannot
prove ownership on any exit path. Reproduced identically under the Linux
x86-64 znc — target-independent typed-checking, not a backend defect.
The checker is behaving as specified (fail-closed on ambiguous ownership);
the fixture was under-specified.
Fix: cherry-picked upstream `2651cee` ("test(arm64): preserve ownership on
repr C early exits", same base `9a2af43`), which rewrites the fixture to
borrow the buffer via `@borrows_mut` in `inspect_event` so every early
return leaves ownership with the caller, freed on every path. Kept only
the fixture change; the commit's unrelated narrow-cast evidence doc does
not exist on this base. Commit `8384c6c`. Verified: compiles to a signed
Mach-O and exits 42 (the expected witness).

### C-018 — manifest `{ link, path }` dep treated as package edge by toolchain-identity closure — REAL-BUG — FIXED 4f0a979
Evidence: after C-016/C-017, the release gate reached `run_macos_dylib.sh`'s
manifest-link step and `znc` refused the build with
`znc: cannot verify toolchain identity: dependency manifest closure is invalid`.
The generated `zag.mod` declares
`helper = { link = "helper", path = "../libs" }` — a native linker input
(library name plus search directory), not a source package. But
`package_manifest_parse` in `selfhost/package_resolve.zag` classified any
deps table mentioning `path` as a package edge, so
`package_manifest_closure_visit` required `../libs/zag.mod`, hit
`manifest_dependency_missing`, and `znc_verify_toolchain_identity` refused
every build in that project. Reproduced standalone: the same manifest +
build against the retained artifacts dir failed identically before the
fix and produced `linked-app-ok` (exit 0) after.
The bug was born red at `f25cbbe`: the test and the identity check shipped
in the same commit, and `package_resolve.zag` was unchanged since — the
manifest-link sub-check could never have passed on this base.
Fix: cherry-picked upstream `5370393` ("fix(manifest): classify native
link paths outside package closure"), which extends
`package_manifest_link_table_valid` to accept an optional `path` field and
short-circuits any deps table mentioning `link` as a compiler/linker input
outside the source closure. Commit `4f0a979` (excluded the commit's
unrelated SENTINEL_NARROW_CAST_EVIDENCE.md, absent on this base).
Verified: `package_closure_test.zag` passes 11/11 including four new
regression checks; `tests/run_macos_dylib.sh` PASS end-to-end
("33 negative cases"); bootstrap fixpoint re-established at stage 3 with
the fix compiled in.

### C-019 — three matrix suites exec the pinned Linux `./znc` on Darwin — REAL-BUG (test scripts) — FIXED c4299f5
Evidence: matrix FAIL(126) for `run_resource_embed.sh` and
`run_foreground_cache_integration.sh`, FAIL(1) for
`run_package_resolution.sh` — every check reported
`znc: cannot execute binary file` (rc=126). All three defaulted
`compiler`/`znc` to `./znc`/`$root/znc`, the pinned Linux x86-64 ELF,
instead of `zag_native_compiler` (`./znc-macos-arm64` on Darwin) as
`run_semantics.sh` and sibling suites do. The suites are
platform-agnostic compiler gates in `DEFAULT_TEST_TARGETS`, so the
correct fix is native resolution (not the Linux-only `exit 2` guard used
for ELF-authority suites).
Fix: resolve via `zag_native_compiler` (preserving `ZNC` override), in
commit `c4299f5`. Verified standalone: resource-embed PASS (with
legitimate Linux-ARM64 cross-exec SKIP), foreground-cache PASS,
package-resolution `pass=42 fail=0`.

### C-020 — relocated audit wrapper loses `znc-real`, breaking nested
compiler staging — REAL-BUG (test scripts) — FIXED c4299f5
Evidence: `run_macos_zagscript_authority.sh` matrix run reported
`pass=39 fail=6`. Four fails traced to
`<tmp>/compiler/znc: line 17: <tmp>/compiler/znc-real: No such file or
directory` — the authority suite's signature-auditing `znc` wrapper
resolves `znc-real` relative to argv[0], and nested suites
(`run_script_allocation_accounting.sh`, `run_script_lifetime.sh`,
`run_script_json_root.sh`) symlinked the wrapper into their own
`compiler/` staging dir, orphaning `znc-real` (rc=127/1).
`run_reference_dynamic_plugin_macos.sh` documented this exact failure
mode and staged `znc-real` beside the symlink.
Fix: upstream `7df3d2a` substance — replace compiler symlinks with an
`exec %q` forwarder so the wrapper keeps its original argv[0] directory
(also applied to `run_reference_dynamic_plugin_macos.sh` per upstream's
revision), and `run_script_json_installed.sh` now installs the underlying
native binary and re-audits each fixture into the parent evidence log.
Commit `c4299f5`. Verified: `run_macos_zagscript_authority.sh` reports
`pass=45 fail=0 signed-artifacts=165 unique-artifacts=156`.

### C-021 — `run_macos_link_options.sh` declares a package dep without the
dep's manifest — REAL-BUG (test fixture) — FIXED c4299f5
Evidence: after C-018, the suite died at the unguarded source-dependency
build with `znc: cannot verify toolchain identity: dependency manifest
closure is invalid`. The fixture appended
`helper = { path = "vendor/helper" }` to the root `zag.mod` but never
wrote `vendor/helper/zag.mod` — the manifest-closure verifier correctly
requires a manifest per package dep (`manifest_dependency_missing`), so
the fixture itself was malformed. Second fixture bug: the hot-patch loop
restored the root manifest but not the original standalone `main.zag`,
leaving an undeclared `pkg:helper/value.zag` import that would fail for
the wrong reason.
Fix: upstream `f7cf1a8` — create the child `zag.mod` before the builds,
append the native dep to the existing child manifest, and restore both
manifest and `main.zag` before hot-patch checks. Commit `c4299f5`.
Verified: `macOS link options: pass=59 fail=0` — matches upstream's
documented 59/59.

### C-022 — exponential nested-aggregate re-typechecking stalls the release gate — REAL-BUG — FIXED 6d35521
Evidence: the release gate reached `run_v2_aggregate_provenance.sh`'s
`owner-deep-clear` fixture (64-level nested struct literal) and
`znc-gen2 check main.zag --no-zagd --no-analyze` ran >19 minutes at 99%
CPU with no bound (`reject_check` invokes `znc check` directly).
`zt_expr_type` in `selfhost/typed.zag` typechecked every struct-literal
field once for diagnostics and a second time for field compatibility —
doubling recursive work per nesting level, so a depth-64 literal is
intractable.
Fix: cherry-picked upstream `b26248f` — keep each field's `ZTExpr` and
reuse it for the compatibility check (includes the
`sentinel_nested_field_mismatch.zag` fixture and
`run_sentinel_aggregate_scaling.py` bounded witness harness; excludes
the unrelated evidence doc). Commit `6d35521`.
Verified: scaling harness and the gate fixture complete in seconds
post-fix (see STATUS); bootstrap fixpoint re-established at stage 3.

### C-023 — ARM64 `.cast_` lowering keeps high bits / wrong sign on sub-64-bit integer casts — REAL-BUG — FIXED fd4bdbf
Evidence: `0x1FF80 as i16` must produce -128 (0xFF80 sign-extended) but a
compiled repro returned `a != -128` → exit 1 under `znc-macos-arm64`
--target macos-arm64. In `selfhost/native/acodegen.zag`
`ac_lower_expr`'s cast path, `u8`/`i8` both emitted `and 255` (i8 was
normalized as UNSIGNED — `0x180 as i8` produced 128 not -128), and
`i16`/`u16` targets received NO normalization at all, so explicit casts
could carry stale high bits into subsequent operations.
Fix: cherry-picked upstream `0377316` — route `i8`/`u8`/`i16`/`u16`/`i32`/
`u32` cast targets through `ac_emit_cabi_int_normalize` (sign-extend for
signed, zero-extend for unsigned). Includes the 25-output sentinel
narrow-cast matrix (`sentinel_narrow_cast_matrix.zag` + `.expected` +
`run_sentinel_narrow_cast_matrix.sh`) and wires it into
`run_macos_arm64_release.sh` immediately after the fixpoint stage, so a
regression can never again ship inside a qualified artifact.
Verified: repro exits 0 post-fix; sentinel matrix diff clean; fixpoint
re-established at stage 3.

## Release gate resolution

`test-macos-arm64-release` completed `pass=69 fail=0` on the final
fixpoint compiler (seed/fixpoint sha256
6b5e7b6e6816f4a3f661251f5489d850d329618bf44db3cb8106b8ab8c9a9fc1 —
byte-identical to upstream's documented all-patched compiler). The gate
includes the new narrow-cast sentinel row (25 outputs), the previously
intractable 64-level aggregate-provenance fixture, manifest-link dylib
coverage, ZagScript authority 45/0 with 165 signed artifacts, the full
object/dylib/static-link/repr-C suite under SDK autoselection, and the
seed-intake identity check.

### C-024 — `test-zagd-product` transient FAIL under matrix load — PLATFORM-ARTIFACT (load contention) — CLOSED
Evidence: the fresh 55-target Darwin matrix run recorded FAIL(2) for
`test-zagd-product` immediately after the suite's embedded 3-stage
bootstrap (~20 min) while the machine was still saturated. Two direct
serial re-runs of `tests/run_zagd_product.sh` each printed
`zagd product: pass` rc=0 (first retained at
`/tmp/zagd-product-rerun.log`; second printed the same line to console,
not tee'd to a file). Same class as C-015 — daemon lifecycle timing
under load, not a product defect.

### Matrix outcome (fresh, final fixpoint)

All 55 `DEFAULT_TEST_TARGETS` rows on Darwin-arm64 under the final
fixpoint compiler (4f0a979+6d35521+fd4bdbf):
54 PASS, 1 transient FAIL re-verified as C-024. The run includes
`test-macos-arm64-release` (embedded 69-check gate, second green pass)
and `test-bootstrap` (independent 3-generation repro proof).

Ancillary note: `tests/run_sentinel_aggregate_scaling.py` (exploratory
witness harness from upstream b26248f) tripped `check_pure_zag_tree.sh`'s
blanket `*.py` prohibition and was removed in `574841c`; the Zag fixture
and the depth-64 release-gate fixture cover the same regression.
