#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

require() {
    local file=$1
    local text=$2
    if grep -Fq "$text" "$file"; then
        echo "  ok  $file contains: $text"
    else
        echo "  XX  $file missing: $text"
        fail=$((fail + 1))
    fi
}

forbid() {
    local file=$1
    local text=$2
    if grep -Fq "$text" "$file"; then
        echo "  XX  stale claim in $file: $text"
        fail=$((fail + 1))
    else
        echo "  ok  no stale claim in $file: $text"
    fi
}

require docs/SUPPORT.md "Linux AArch64 | supported scoped target"
require docs/SUPPORT.md 'Apple Silicon macOS (`macos-arm64`) | scoped native development target'
require docs/SUPPORT.md "Mach-O object, archive, and shared-library output are"
require docs/SUPPORT.md 'BSS-backed'
require docs/SUPPORT.md '`--safety=checked`'
require docs/SUPPORT.md '`--sanitize=memory`'
require docs/SUPPORT.md '`--debug` combined with dyld imports'
require docs/SUPPORT.md 'external `-l`/`-L` linking'
require docs/SUPPORT.md "Linux x86-64 syscall-number"
require docs/SUPPORT.md "Unknown or computed raw syscall numbers return"
require docs/MACOS_NATIVE_PARITY.md "not a claim of Linux AArch64 feature parity"
require docs/MACOS_NATIVE_PARITY.md 'Mach-O object (`.o`), archive (`.a`), and shared-library (`.dylib`) output'
require docs/MACOS_NATIVE_PARITY.md "An unknown Linux number or a computed raw syscall number returns Darwin"
require docs/MACOS_NATIVE_PARITY.md "mkdir (Linux 83 to Darwin 136)"
require docs/SUPPORT.md "package registry"
require docs/SUPPORT.md "destructors and RAII | unavailable"
require docs/SUPPORT.md "async/await | unavailable"
require ../README.md "zag-poc/docs/SUPPORT.md"
require README.md "docs/SUPPORT.md"
require INSTALL.md "docs/SUPPORT.md"
require AGENTS.md "docs/SUPPORT.md"
require ../README.md "native development target"
require README.md "executable-only"
require INSTALL.md 'or computed numbers return `ENOSYS`'

forbid README.md "experimental ARM64 Linux ELF"
forbid README.md "ARM64: experimental"
forbid INSTALL.md "x86-64 Linux only"
forbid AGENTS.md "AArch64 Linux (fully supported)"
forbid docs/SUPPORT.md "macOS, Windows, BSD, RISC-V | unsupported"
forbid docs/MACOS_NATIVE_PARITY.md "macOS native-parity contract"
forbid docs/V2_TARGET_SUPPORT.md "| v1 supported; not yet a v2 machine-control target"
forbid ../README.md "Apple Silicon macOS use platform-scoped seeds and support gates"
forbid INSTALL.md '`znc-macos-arm64` release/CI artifact as its bootstrap seed'

echo "════ docs truth fail=$fail ════"
[ "$fail" -eq 0 ]
