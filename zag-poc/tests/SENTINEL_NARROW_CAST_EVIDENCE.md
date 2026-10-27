# SENTINEL native ARM64 narrow-cast correctness — 2026-10-26

Independent development branch `research/sentinel-zag-narrow-casts-20261026`, base commit `9a2af437e45e95fd58e815fd036a94b85726893a`. Mac ARM64 native target, Zag compiler generated from `selfhost/native/znc.zag`. Source policy: `docs/X86_TARGET_POLICY.md` specifies low-bit wrap on explicit narrowing and signed/unsigned normalization at integer boundaries; these tests check corresponding ARM64 behavior. They are a bounded regression corpus, not a certification of all integer conversions or architectures.

## Reproducer and cause

```zag
let value:u64 = 65536;
print_u64((value as u16) as u64);
```

Expected stdout: `0`. Old ARM64 compiler observed: `65536`. Other old compiler failures include `(255 as i8) as i64 == 255` instead of `-1` and `(65535 as i16) as i64 == 65535` instead of `-1`. The explicit `.cast_` lowering in `selfhost/native/acodegen.zag` omitted i16/u16 normalization and incorrectly masked i8 as unsigned. The patch calls the existing integer normalization routine `ac_emit_cabi_int_normalize` for signed/unsigned 8, 16 and 32 bits. The fixture tests runtime-parsed and constant inputs, signed to unsigned and reverse, narrowing then widening, arithmetic, comparisons, locals, returns, and narrow memory stores/loads.

## Immutable baseline and patched identities

| Artifact | SHA-256 |
| --- | --- |
| Old-source compiler | `f83ff168fd0e03cf5c68fc9233064308a5213a07629f2b17c747e42bbd838214` |
| Patched compiler generation 1 | `12ccffdd6486049b9b2282a2c16c5367c9fd413a5545d137ca7735eb5ddd74cc` |
| Patched compiler generation 2 | `12ccffdd6486049b9b2282a2c16c5367c9fd413a5545d137ca7735eb5ddd74cc` |
| Cast fixture source | `162d83d62780383ad93661b8a52e1aee5568fc767ea52603fd7158c188e84871` |
| Patched source `acodegen.zag` (prior to gate integration) | `1899ab05d74322502f1b977c61a52cf5732f6e7b331b710d54ee1665a7d65165` |

## Tests executed

- Original-source compiler: 25-line exact stdout matrix FAILED, including the native minimal reproducer. Preserve original stdout, not rewritten expected output.
- Patched self-hosted compiler: same matrix PASS with all 25 outputs; compilers generated at stages 1 and 2 are byte-identical.
- Previous SENTINEL native 4-line high-bit minimum, 19-line unsigned matrix, 6-line narrow-cast minimum: all PASS under patched compiler. The old-source compiler fails the 19-line unsigned case at its 15th output (explicit u16 normalization), and five narrow-cast outputs.
- `ZNC=<patched> bash tests/run_native_arm64.sh`: **101 pass, 0 fail**, including signed native Mach-O execution. This is a broader backend regression, not the full release gate.
- Recompiled AXIOM UI07/UI08 exploratory erasures and UI10/UI11 development journal trials with patched compiler: their native stdout matched the old compiler's already reproduced outputs exactly, showing **no observed difference in these fixtures**. This does not rule out effects in other TNN programs or guarantee all high-bit arithmetic semantics.

To reproduce the regression against a specific pinned compiler:

```sh
ZNC_BIN=/absolute/path/to/znc-macos-arm64 bash zag-poc/tests/run_sentinel_narrow_cast_matrix.sh
```

The file `fixtures/sentinel_narrow_cast_matrix.expected` is the *fixed mathematical oracle*, not an output updated to match a failing compiler. `run_macos_arm64_release.sh` includes the regression for subsequent release qualification; running the new test alone does not establish the full release gate's success.

## Independent macOS release-gate environment diagnosis (2026-10-26)

The complete native macOS ARM64 release gate was executed using the fixed-point patched compiler (`12ccffdd6486049b9b2282a2c16c5367c9fd413a5545d137ca7735eb5ddd74cc`). Its first run reached the Mach-O/C interoperability phase after rebuilding byte-identical generation-1 and generation-2 compilers, passing all 25 narrow-cast fixture lines, passing the native dyld/Objective-C cases, and passing the 25-case live hot-reload check. The complete gate **exited 1** in `tests/run_macos_object.sh` when `xcrun clang` attempted to link `caller.c` with generated Zag Mach-O object files. The installed CLT macOS **27.0** SDK's `libSystem.tbd` contained an architecture string the Apple linker rejected:

```text
ld: tapi error: malformed file
/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk/usr/lib/libSystem.B.tbd:4:20: error: unknown architecture
                   arm64e.x1-macos, arm64e.x1-maccatalyst ]
```

`xcrun --show-sdk-path` resolved `MacOSX27.0.sdk`; `clang --version` identified Apple clang 21.0.0 (clang-2100.1.1.101). As an independent environment control, the same `int main(void) { return 0; }` C source **linked successfully** with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` and **failed** with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk`. With SDK 26.5 explicitly selected, the complete `tests/run_macos_object.sh` Zag/C ABI interoperability suite **passed** using the same patched compiler SHA. Therefore this original full-gate failure is at the external Apple SDK/linker boundary; it is not evidence of a Zag narrow-cast regression. The overall release-gate qualification requires a complete run with a usable SDK.

Reproduce the controlled external-link stage without editing installed SDKs or changing compiler source:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
ZNC=/absolute/path/to/patched-znc \
bash zag-poc/tests/run_macos_object.sh
```

## Second full release attempt: independent pre-existing ownership fixture failure

With SDK 26.5 selected, a second complete `tests/run_macos_arm64_release.sh` run progressed through compiler generation-1/2 self-host fixpoint, all 25 narrow-cast outputs, dyld/Objective-C, all 25 hot-reload checks, and the native object/archive/encoder suites. It then **exited 1** at `tests/run_repr_c_layout.sh`, where the original `repr_c_xbutton_event.zag` fixture scored `pass=7 fail=1` and emitted **38 E0204 ownership errors**. The run's stdout SHA-256 was `21e72d8cbf103db0bf4828de4cbdaecbed9afdee823e2baf3c1d1a07c1ed3ba1`, stderr `95b459076acd4618e9ad558211843212865eb91e8eed48c85436c370c94d0540` (retained under untracked `.sentinel-build/` locally, not represented as frozen remote evidence).

The original fixture (`fb80615098c00046b02f7d3d4276849fe0b790e22b8cf3a01ae2baf907f3fe7f`) created an owning `raw` allocation and a `*XButtonEvent` alias, performed many early-return layout checks, and freed only at the successful final path. The edition-2027 ownership checker correctly rejected the alias and unreleased failure paths. **Old-source compiler** SHA-256 `f83ff168fd0e03cf5c68fc9233064308a5213a07629f2b17c747e42bbd838214` and **patched compiler** SHA-256 `12ccffdd6486049b9b2282a2c16c5367c9fd413a5545d137ca7735eb5ddd74cc` each produced `pass=7 fail=1` and the same 38 E0204 diagnostics on the unmodified source. The fixture and runner were byte-identical to the compiler base commit. This failure **predates and is independent of** the narrow-cast repair.

A minimal fixture-only correction moves the actual `XButtonEvent` byte-access checks into `inspect_event(raw: @borrows_mut *u8)` and keeps allocation and exactly-once release in `main`, after the helper returns any result. The corrected fixture SHA-256 is `05903b267bcc37d60c52313f6df9620e872a7331bf332c2ae992e41538b5f0b9`. Under both old-source and patched compilers, the independently executed native fixture returns exit code **42**, and the complete `run_repr_c_layout.sh` scores **9/9 pass** with valid signed ARM64 Mach-O, C field offsets, 96-byte stride, narrow store sentinel checks, and fail-closed negative cases. Both suite stdout streams are byte-identical (SHA-256 `9b13387854445fd6d58675c5db870fe174f62283c407703fb4d2804f136ee0e5`). This fixes the test harness's ownership semantics without changing the C-layout assertions or weakening the compiler's ownership checker.

Reproduce both historical compiler controls against this exact corrected source:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
ZNC=/absolute/path/to/old-or-patched-znc \
ZNC_TARGET=macos-arm64 bash zag-poc/tests/run_repr_c_layout.sh
```

The entire macOS release gate remains a separate qualification requirement; do not infer a full pass from this targeted fixture control.

## Third full release attempt: source-package closure rejects native library manifests

With the corrected ownership fixture and SDK 26.5, a third full gate reached `tests/run_macos_dylib.sh` after passing the previously failing stages. It exited 1 when compiling a manifest-linked executable: `znc: cannot verify toolchain identity: dependency manifest closure is invalid`. This was independently reproduced with both the before-narrow-cast and after-narrow-cast compilers, so it is not a narrow-cast regression. The test manifest declares `[deps] helper = { link = "helper", path = "../libs" }` and the test's actual `../libs` contains a native dynamic library, not a source package manifest.

In `selfhost/package_resolve.zag`, `package_manifest_parse` previously classified any dependency with a `path` field as a local source edge even when a `link` field was also present. `package_manifest_closure_visit` then attempted to read `../libs/zag.mod` and rejected a valid linker-only manifest. The compiler's existing `znc_macos_manifest_links` separately recognizes `link` plus optional `path` and passes them to the native linker. This inconsistent classification broke toolchain-identity validation before the linker could run.

On the isolated SENTINEL Zag branch, `package_manifest_link_table_valid` now accepts **exactly one** nonempty quoted `link` field and at most one nonempty quoted `path` field in either order, and rejects duplicate/unknown fields. The package-closure parser classifies the strictly validated native linker entry outside source-package edges. It continues to validate source package paths and vendor modes separately. Four added native package-closure tests reproduce the failure (the original parser scored **9 pass, 2 fail** across the 11 cases) and pass after the fix (**11/11**). These are new development tests; no frozen evidence changed.

An independently generated signed native ARM64 compiler, SHA-256 `6e98eb65ce7ad45098ba211db2d0d900358f7d627f727516b8724d9c7e18a5bd`, passed the **complete** `tests/run_macos_dylib.sh` with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. This includes executable `manifest-link` and transitive `imported-manifest` cases plus **33 negative cases**, signing, dynamic libraries, dylib symbol/ABI interop, SDK/framework resolution, and relocation. Captured stdout SHA-256 `ffb832b3b5a8d3aac12015bd76c07a836e224247555ea3db137f3dcfc43ba75a`; stderr is empty (SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`). Source SHA-256: `selfhost/package_resolve.zag` `10c9b955f989e4184ee54c2d2da33529f4758ab7400af157458b7417e7b2b212`; `selfhost/package_closure_test.zag` `953857959a460d253f21be04531ae0905f6007de646c6cb7c8c11c004df00955`.

Reproduce the targeted result from the `zag-poc` directory using the newly built corrected compiler:

```sh
ZNC=/absolute/path/to/znc-manifest-fixed-gen1 \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
bash tests/run_macos_dylib.sh
```

The full native ARM64 release gate is a separate qualification. All raw local logs are retained under `.sentinel-build/` outside the tracked report.

## Fourth full release attempt: historical dynamic-loader fixture missing

With the strict native-manifest classification fix, the fourth native ARM64 full release attempt passed self-host fixpoint, narrow casts, the corrected `@repr(C)` fixture, and the **complete** `run_macos_dylib.sh` production linker suite. It stopped at `run_macos_dylib_format.sh` when Apple clang could not find `tests/fixtures/macos_dylib_loader.c`. This C test witness was absent in the current checked-out tree but survives **unchanged** in historical Zag commit `bb37154` (`ZagScript 1.0 qualification snapshot`), so this is a pre-existing missing-fixture packaging defect rather than a new compiler-lowering failure.

The exact historical fixture was restored using `git show bb37154:zag-poc/tests/fixtures/macos_dylib_loader.c` to the same path on the isolated review branch. Historical/current SHA-256: `1ac47bb3cf608ceb3cb81f565740f3657ce91b21f5a8a2f610fd7723e99cc62f`. Under the manifest-corrected compiler with SDK 26.5, **the complete** `tests/run_macos_dylib_format.sh` passed: three `dlopen`/`dlsym`/`dlclose` cycles, 305 exports, function/data rebase/bind, deterministic signed dylibs, FAT/thin dependency parsing and invalid input checks. This is an exact archived fixture recovery, not reconstruction or a claim that other missing files exist.

Reproduce from `zag-poc/` with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ZNC=/absolute/path/to/znc-manifest-fixed-gen1 bash tests/run_macos_dylib_format.sh`. The subsequent **full** native ARM64 release gate is separately required and is not implied by this suite pass.

## Fifth gate: nested aggregate typechecking performance defect

The fifth native macOS ARM64 gate, using the prior corrected compiler SHA-256 `6e98eb65ce7ad45098ba211db2d0d900358f7d627f727516b8724d9c7e18a5bd`, SDK26.5, and restored dynamic-loader fixture, passed its native compiler fixpoint, narrow casts, corrected `@repr(C)`, linker tests and **101/101 ARM64 backend corpus**. It then stalled at `run_v2_aggregate_provenance.sh`'s depth-64 `owner-deep-clear` fixture: a native compiler consumed one CPU core for minutes, used a multigigabyte memory footprint, and never finished. The fifth gate was deliberately terminated after preserving a process sample and the raw streams (exit 143). This was a genuine pre-existing compiler performance defect, not a test pass or a regression from the previous fixes.

Source cause: in `selfhost/typed.zag`'s `zt_expr_type`, `.slit_` recursively typechecked every struct-literal child to aggregate diagnostics, then recursively rechecked the same child to verify field compatibility. For a one-field nest the work nearly doubles per additional level. In two independent compiler identities, depth-12 full fixtures took ~0.039 s, depth 16 ~0.6–0.7 s, depth 20 ~10.7–10.8 s and depth 24 **timed out** at 12 seconds. An isolated `types`-only depth-20 control took 0.003 s, while `literal`-only depth-20 exceeded the same timeout. The slowdown therefore originates from expression typechecking rather than owner field clearing.

The minimal patch caches each child `ZTExpr` in an `ArrayList` during the first recursive validation, reuses the cached types in both field-compatibility paths and frees the short-lived array before returning. A native signed ARM64 compiler built from this source has SHA-256 `6b5e7b6e6816f4a3f661251f5489d850d329618bf44db3cb8106b8ab8c9a9fc1`; changed `selfhost/typed.zag` SHA-256 `dfec2952899cfe5759196ce300b9d3b144376f2ceb5d943252d5d09d33cf1cb3`. With the identical development fixture, full depth 20 compiled in **0.005 s**, depth 32 in **0.008 s**, and depth 64 in **0.018 s**. Across `literal`, `owner`, `clear`, and `full` modes at depths 4, 8, 12, 16, 20, 24, 32, and 64, **all 32 bounded native typechecks completed successfully**. This is a directly reproduced improvement, without asserting global compiler complexity.

The unchanged edition-2027 aggregate provenance suite passed **20/20**, including both 64-level owner and stack field clears, after resolving the generated compiler's expected relative `std`/`selfhost` module lookup paths. The preceding 19/20 run failed only because those module paths were absent beside the freshly built compiler binary, with `@import cannot read` for `std/list.zag`. The native 25-output narrow-cast oracle passed unchanged. New `tests/fixtures/sentinel_nested_field_mismatch.zag` independently confirms that incorrect nested field type `[]u8` remains rejected against expected `i32` with `E0203`; old compiler logs repeated that error 23 times versus five times with the caching fix, revealing other duplicate-emission sites but preserving the semantic rejection.

Reproduce using pinned compiler paths from `zag-poc/`:

```sh
python3 tests/run_sentinel_aggregate_scaling.py /absolute/path/to/native-znc --depths 4,8,12,16,20,24,32,64 --modes literal,owner,clear,full --timeout 12 --output /absolute/path/to/results.json
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ZNC=/absolute/path/to/native-znc bash tests/run_v2_aggregate_provenance.sh
ZNC_BIN=/absolute/path/to/native-znc bash tests/run_sentinel_narrow_cast_matrix.sh
```

Raw local evidence remains outside Git in `.sentinel-build/aggregate-scaling-{baseline,patched,isolation,cache-fix}.json`, `.sentinel-build/aggregate-provenance-fixed-2.{stdout,stderr}`, `.sentinel-build/{before,cached}-field-mismatch.stderr`, `.sentinel-build/full-release-restored-loader.{stdout,stderr}`, and `.sentinel-build/deep-aggregate-sample.txt`. These development tests do not establish a completed **full** ARM64 release-gate pass; that requires a fresh exit status 0 and `fail=0`.

## Sixth gate blocker: macOS link-options test retained invalid source state

The next full ARM64 gate progressed through signed self-host compilation, native narrow casts, dynamic library suites and the once-blocking 64-level aggregate provenance stage, but exited 1 in `tests/run_macos_link_options.sh`. This runner first created a root source-package reference `helper = { path = "vendor/helper" }` without writing the imported package's required `vendor/helper/zag.mod`. The stricter, correct manifest-closure checker rejected that malformed test fixture. A first correction supplied the child manifest but exposed a second test setup bug: the later hot-patch phase restored the root `zag.mod` without restoring the original `src/main.zag`, so its remaining `pkg:helper/value.zag` import was undeclared. The hot-patch checks then failed for the wrong reason, before option validation could occur.

Only the test fixture runner was corrected: create a valid child package manifest for the source-only import, append the native dependency declaration to that existing child manifest for the negative tests, and restore **both** original root manifest and standalone `main.zag` before the hot-patch validation loop. The native linker restrictions and package-closure checker are unchanged. The corrected script SHA-256 is `d0f1cdeb26671a4b79299b2a31e6f0eaa35148c707fb0f6cd73ba1d2d9029e5c`.

With SDK26.5, both independent exact compiler identities — pre-fix `f83ff168fd0e03cf5c68fc9233064308a5213a07629f2b17c747e42bbd838214` and all-patched native ARM64 `6b5e7b6e6816f4a3f661251f5489d850d329618bf44db3cb8106b8ab8c9a9fc1` — passed **59/59** link-options checks with `exit 0`, byte-identical stdout SHA-256 `d426f7ba2dd18adbfbd49822264cd950a732a0d86503d1791ae1d0be90ed9c34`, and empty stderr. This independently identifies a pre-existing runner fixture problem, not an observed release-linker regression. Reproduce from `zag-poc/`:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
ZNC=/absolute/path/to/old-or-corrected-znc bash tests/run_macos_link_options.sh
```

Raw logs: `.sentinel-build/macos-link-options-{old-compiler,fixed-3}.{stdout,stderr}`. A complete fresh ARM64 release gate with the corrected runner was started subsequently; its final qualification outcome must be recorded from that attempt's exit status.

## Seventh gate investigation: native ZagScript authority and test custody

The subsequent full release attempt reached `tests/run_macos_zagscript_authority.sh` and exited 1: its first invocation recorded `pass=38 fail=7`. An independent replay identified fixture execution failures, including a release signing wrapper relocated without its `znc-real` sibling. The dynamic plugin test additionally symlinked the wrapper as **both** `znc` and `znc-real`, recursively forking until the process limit rejected further children. Four test runners now preserve the **original absolute wrapper path** through a local forwarding script; the dynamic plugin path no longer creates a self-referential `znc-real`. The restored original `run_script_interpolation_project.sh` was retrieved directly from Zag commit `bb37154` (SHA-256 `f055ac483ada1317bd98639a418de6251b714875a9921d8b778fbc289b222442`). It is historical source recovery, not independently invented evidence.

The JSON installed-layout test copied wrapper script bytes without its dependent binary. The amended test detects the release wrapper, installs the **same compiler binary** from its `znc-real` sibling into the staged prefix, and explicitly verifies/records each produced arm64 Mach-O signature in the original audit logs. The installed-prefix import test now passes without silently substituting a different compiler. The authority runner's generated `invalid.zag` also had a malformed multiline `||` condition; this was corrected without weakening its invalid-list-state assertion.

Allocation accounting revealed a stale expected 1,048,520-byte total for `process_run_timeout("printf bounded",1000,1048400)` under Script arena policy. Both original and patched compiler binaries independently charged **1,048,504**, exactly matching the source implementation: pipe pair 8, command 15, argv 32, envp 8, output buffer 1,048,401, status 8 and result handle 32 bytes. The additional 16-byte ownership header is required only by *bounded-heap policy 2*; the authority fixture uses the arena policy. The fixture's expected constant is now 1,048,504. The original process-boundary stress suite also independently passes without editing its resource checks. This discrepancy was a **test-oracle defect**, not a reproduced compiler arithmetic or allocator failure.

With these isolated test-runner corrections, the independently invoked full macOS ZagScript authority **exited 0: 45/45 sections passed, zero failures, 165 signed-artifact observations, 156 unique artifact paths**, under SDK 26.5. Exact patched signed compiler SHA-256: `6b5e7b6e6816f4a3f661251f5489d850d329618bf44db3cb8106b8ab8c9a9fc1`. Raw authority stdout SHA-256: `2351fdba33b68934ae0f2f06e0b555e5c7de9ef81d5de3c52f2f7e4659b7d61d`; stderr SHA-256: `ac825bc4680ffb42603cdf927c7d2877fa66737b7af22f802bd5166d1a0ab006`. Raw files are `.sentinel-build/zagscript-authority-remediated.{stdout,stderr}` and are retained locally outside Git. This proves **the ZagScript authority section**, not a completed full macOS compiler release gate.

## Eighth gate: missing installed standard-library transitive dependency

The next complete macOS ARM64 release attempt (SDK 26.5, native compiler SHA-256 `6b5e7b6e6816f4a3f661251f5489d850d329618bf44db3cb8106b8ab8c9a9fc1`) passed the fixed-point compiler, 25/25 narrow casts, 101/101 backend, 20/20 aggregate provenance, 59/59 link options, 25/25 hot reload, 45/45 embedded ZagScript authority, release-package layout and 17/17 LSP checks. It nevertheless **exited 1** immediately after printing `Installed tools` in `tests/run_zagscript_install_layout.sh`. Preserved complete stdout and stderr SHA-256: `a416386b3560ad7bc7e05b5a2df2a87d370d41c45e5bbb0a3f213897af52f7ee` / `6aede560ec9d97917cf96d18c694b17352f097aa69518457420f8cffc281b897` in `.sentinel-build/full-release-authority-fixed.{stdout,stderr}`.

An independent `bash -x` run localized the silent `set -e` failure to the first post-install compile of `all-prelude.zag`. Reproducing the production `make install` recipe in an isolated temporary prefix and retaining the compiler's formerly discarded stdout produced the exact diagnostic: `zag: error: @import cannot read '.../prefix/lib/zag/std/process_platform.zag'`. The installed `znc` was byte-identical to the verified compiler. `selfhost/std/process.zag` directly imports `process_platform.zag`, but the installer copied the former and omitted the latter. This is a pre-existing **production packaging/integration defect**, independent of compiler cast lowering or TNN experiment scores.

The isolated review branch now installs `selfhost/std/process_platform.zag` into `lib/zag/std/` and makes the production installation test assert its presence in `make -n install`. The unchanged full staged-install test **exited 0** with the same pinned native compiler, daemon and LSP, compiling and running the installed Script prelude, JSON import and hello program. Fixed targeted stdout SHA-256 `4a472b4be719781ca21ec480382e23eb1d311fd5addea7c1ad269acc48277d48`; stderr SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. Source SHA-256: `Makefile` `ecec3ecb8b072850b8d33b57d22881d339c984dc42623fa060fa75bdf3641e9e`; `tests/run_zagscript_install_layout.sh` `ce1151cc58456aa687f7b5c82230946e29049024689fd674565ef318be9c34e5`; installed module `selfhost/std/process_platform.zag` `e2e8eb33b3eb1ead629999bc6ae640e374be11e2ed82ad1881b375fb27391edd`.

Reproduce the targeted installed layout from `zag-poc/` using `ZNC=/absolute/path/to/verified-znc ZAGD=/absolute/path/to/native-zagd ZAG_LSP=/absolute/path/to/native-zag-lsp SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash tests/run_zagscript_install_layout.sh`. The complete full release gate must independently exit 0 to establish qualification.

## Ninth gate: missing historical seed-intake and packaging helpers

After the installed-module correction, the subsequent complete native ARM64 gate passed both self-host compiler generations, narrow casts, native runtime/backend suites, 45/45 embedded ZagScript authority, release layout, 17/17 LSP checks and the **production installed-prefix suite**. It then **exited 127** on `bash: tools/bootstrap-macos-seed.sh: No such file or directory` at the final seed-intake check (`tests/run_macos_arm64_release.sh:668`). This is a missing release-distribution input, not a compiler arithmetic failure. Preserved local `.sentinel-build/full-release-install-fixed.{stdout,stderr}` hashes: SHA-256 `4335310f6dfff97eb269b0406a4fbc74643b9b88b8ab04447136b3a2e801b9bb` / `001204610e6077605824849c93762f2fbfd0b166f743959690e372e0f0263441`.

Both missing `tools/bootstrap-macos-seed.sh` and `tools/package-release.sh` exist in historical Zag commit `bb37154403028ac58ba865cd90383b0ca463f01d`. The exact original files were restored on the isolated Zag branch without modifying their bytes: Git blob identities `db9710021c791c9c86c034d7893bfab634de7ec8` / `6f11d2ad8bfe2e8ce9ef79904647d4f6d6d407ce`; SHA-256 `51932222188594c2c154ecddcda93c2cffd962498c0a7fa1aabd64b941ecde4b` / `09ca6c8f27b2cea843754913a2b52ddfa939040fd44d62856a07f9f01627e5ab`. Restored-file commit `390f750e6b781add30d8ad76e5610d5a56dd6fe5` was pushed to the isolated research branch. This is historical source recovery, not a replacement implementation described as original.

With pinned signed compiler SHA-256 `6b5e7b6e6816f4a3f661251f5489d850d329618bf44db3cb8106b8ab8c9a9fc1`, the original helper's `--verify-only` accepted an independently produced matching SHA-256 record and rejected an all-zero mismatched digest with the exact diagnostic `macOS seed bootstrap: seed checksum mismatch.`. `tests/run_release_package_layout.sh` passed and `tests/run_docs_truth.sh` exited 0, `fail=0`; both recovered helpers passed `bash -n`. The helper's full mutating clean-checkout bootstrap path and the archive producer have **not** been independently run here. A complete release-gate rerun after restoration is separately required for release qualification.
