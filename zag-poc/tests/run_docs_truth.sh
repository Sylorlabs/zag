#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

require() {
    local file=$1
    local text=$2
    if grep -Fq -- "$text" "$file"; then
        echo "  ok  $file contains: $text"
    else
        echo "  XX  $file missing: $text"
        fail=$((fail + 1))
    fi
}

forbid() {
    local file=$1
    local text=$2
    if grep -Fq -- "$text" "$file"; then
        echo "  XX  stale claim in $file: $text"
        fail=$((fail + 1))
    else
        echo "  ok  no stale claim in $file: $text"
    fi
}

require docs/SUPPORT.md "Linux AArch64 | supported scoped target"
require docs/SUPPORT.md 'Apple Silicon macOS (`macos-arm64`) | scoped native development target'
require docs/SUPPORT.md 'Apple Silicon has a first-class `gpu-metal` target'
require docs/SUPPORT.md '(`--emit-obj`) and BSD archive (`--emit-static`) output'
require docs/SUPPORT.md 'uses `--emit-dylib` (alias `--emit-shared`)'
require docs/SUPPORT.md 'bounded ARM64 Mach-O object/archive input linking'
require docs/SUPPORT.md 'Custom linked images currently reject hot/debug/exit-sanitizer combinations;'
require docs/SUPPORT.md 'BSS-backed'
require docs/SUPPORT.md '`--safety=checked`'
require docs/SUPPORT.md '`--sanitize=memory`'
require docs/SUPPORT.md '`--debug` combined with dyld imports'
require docs/SUPPORT.md 'external `-l`/`-L` linking'
require docs/SUPPORT.md "Linux x86-64 syscall-number"
require docs/SUPPORT.md "Unknown or computed raw syscall numbers return"
require docs/MACOS_NATIVE_PARITY.md "Equivalent user-facing capabilities may use Darwin-specific mechanisms"
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_thread_spawn.sh'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_object.sh'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_repr_c_layout.sh'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_dylib.sh'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_dylib_format.sh'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_static_link.sh'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_metal_loader.sh'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_metal_native_profiles.sh'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_atomic_wait_wake.sh'
require docs/MACOS_NATIVE_PARITY.md '`--target gpu-metal` emits deterministic MSL'
require docs/SUPPORT.md 'same unsafe raw `@atomicWait32`/`@atomicWake32` surface execute on both targets'
require docs/V2_TARGET_SUPPORT.md 'first-class `gpu-metal`'
require docs/V2_TARGET_SUPPORT.md 'pthread-backed raw i32 wait/wake parity'
require docs/V2_TARGET_SUPPORT.md '**bounded runtime verified** on physical Apple Silicon'
require docs/V2_GPU_MODEL.md 'verified (1024/1024 fill plus depth and alpha 0/128/256 blend witnesses)'
require docs/MACOS_NATIVE_PARITY.md 'cache input readers remain no-follow'
require docs/MACOS_NATIVE_PARITY.md 'tests/run_macos_link_options.sh'
require docs/MACOS_NATIVE_PARITY.md 'tools/package-release.sh'
require docs/MACOS_NATIVE_PARITY.md "An unknown Linux number or a computed raw syscall number returns Darwin"
require docs/MACOS_NATIVE_PARITY.md "mkdir (Linux 83 to Darwin 136)"
require docs/MACOS_NATIVE_PARITY.md 'zag-znc-macos-arm64-cross-<commit>'
require docs/MACOS_NATIVE_PARITY.md 'zag-znc-macos-arm64-verified-<commit>'
require docs/SUPPORT.md 'tools/bootstrap-macos-seed.sh'
require docs/SUPPORT.md 'ready-to-install `zag-lang.vsix`'
require INSTALL.md 'znc-macos-arm64.sha256'
require docs/SUPPORT.md "package registry"
require docs/SUPPORT.md "destructors and RAII | unavailable"
require docs/SUPPORT.md "async/await | unavailable"
require ../README.md "zag-poc/docs/SUPPORT.md"
require README.md "docs/SUPPORT.md"
require INSTALL.md "docs/SUPPORT.md"
require AGENTS.md "docs/SUPPORT.md"
require ../README.md "native development target"
require README.md "bounded C-ABI objects/static archives"
require README.md 'bounded ARM64 Mach-O `.o`/`.a`'
require docs/SUPPORT.md 'fixed `f32`/`f64` imports and exports'
require docs/SUPPORT.md 'ten-FP-parameter register/stack overflow'
require docs/SUPPORT.md 'flat/nested small register/stack and large indirect 64-bit-leaf struct imports/exports'
require docs/SUPPORT.md 'leaves may be nested through'
require docs/SUPPORT.md 'flat small integer/bool/pointer struct byte-layout adaptation'
require docs/SUPPORT.md 'unsigned subword fields, padding, `bool`, raw pointers'
require docs/SUPPORT.md 'direct scalar callbacks and mixed/wide FP/GPR f32/f64 callbacks'
require docs/SUPPORT.md 'native parity for the compiler-owned `popcount`/`andn`/leading-zero/trailing-zero/byte-swap scalar CPU controls'
require docs/SUPPORT.md 'bounded TAPI-v4 SDK library plus `-framework`/`-F` lookup'
require docs/SUPPORT.md 'SDK `libNAME.tbd` fallback'
require docs/MACOS_NATIVE_PARITY.md 'Fixed `f32`/`f64` imports and exports use'
require docs/MACOS_NATIVE_PARITY.md 'naturally packed stack overflow'
require docs/MACOS_NATIVE_PARITY.md 'forced small-aggregate stack spill'
require docs/MACOS_NATIVE_PARITY.md 'flat/nested small and large cases'
require docs/MACOS_NATIVE_PARITY.md 'mixed-layout values larger than 16 bytes still reject'
require docs/MACOS_NATIVE_PARITY.md 'callback-alias'
require docs/MACOS_NATIVE_PARITY.md 'target-scoped direct'
forbid docs/MACOS_NATIVE_PARITY.md 'floating-point `@cabi_export`'
forbid docs/MACOS_NATIVE_PARITY.md '`.tbd` or framework-search command-line interfaces'
forbid README.md "executable-only"
forbid docs/SUPPORT.md 'This is not static object/archive input linking'
forbid docs/MACOS_NATIVE_PARITY.md '- static object/archive input linking,'
forbid INSTALL.md 'Static object/archive input linking, floating-point'
forbid docs/SUPPORT.md "Mach-O object, archive, and shared-library output are"
forbid docs/SUPPORT.md 'Shared-library output remains unsupported.'
forbid INSTALL.md 'Shared-library output, arbitrary dylib install names'
forbid docs/SUPPORT.md 'unions, nested aggregates'
forbid docs/MACOS_NATIVE_PARITY.md 'nested aggregate layouts'
forbid docs/MACOS_NATIVE_PARITY.md 'nested C layout'
forbid docs/V2_ABI.md 'nested aggregate layouts'
forbid docs/V2_ABI.md 'unions, nested aggregates'
forbid INSTALL.md 'unions, nested aggregates'
forbid docs/SUPPORT.md 'Mixed-width/HFA/HVA aggregates'
forbid docs/MACOS_NATIVE_PARITY.md 'mixed-width/HFA/HVA aggregates'
forbid INSTALL.md 'Mixed-width/HFA/HVA structs'
require INSTALL.md 'or computed numbers return `ENOSYS`'

forbid README.md "experimental ARM64 Linux ELF"
forbid README.md "ARM64: experimental"
forbid INSTALL.md "x86-64 Linux only"
forbid AGENTS.md "AArch64 Linux (fully supported)"
forbid docs/SUPPORT.md "macOS, Windows, BSD, RISC-V | unsupported"
forbid docs/MACOS_NATIVE_PARITY.md "macOS native-parity contract"
forbid docs/V2_TARGET_SUPPORT.md "| v1 supported; not yet a v2 machine-control target"
forbid docs/V2_GPU_MODEL.md 'Metal remains an explicit fail-closed artifact-only target'
forbid docs/V2_GPU_MODEL.md 'Needs contributor with macOS/Metal'
forbid docs/SUPPORT.md 'raw wait/wake remains Linux-futex-only'
forbid docs/MACOS_NATIVE_PARITY.md 'Darwin `@atomicWait32`/`@atomicWake32` parity is tracked separately'
forbid docs/V2_FINAL_VERIFICATION.md 'CUDA/Metal remain artifact-only'
forbid ../README.md "Apple Silicon macOS use platform-scoped seeds and support gates"
forbid INSTALL.md '`znc-macos-arm64` release/CI artifact as its bootstrap seed'

echo "════ docs truth fail=$fail ════"
[ "$fail" -eq 0 ]
