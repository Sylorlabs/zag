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
