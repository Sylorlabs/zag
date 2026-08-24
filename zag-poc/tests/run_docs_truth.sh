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
require docs/SUPPORT.md "package registry"
require docs/SUPPORT.md "destructors and RAII | unavailable"
require docs/SUPPORT.md "async/await | unavailable"
require ../README.md "zag-poc/docs/SUPPORT.md"
require README.md "docs/SUPPORT.md"
require INSTALL.md "docs/SUPPORT.md"
require AGENTS.md "docs/SUPPORT.md"

forbid README.md "experimental ARM64 Linux ELF"
forbid README.md "ARM64: experimental"
forbid INSTALL.md "x86-64 Linux only"
forbid AGENTS.md "AArch64 Linux (fully supported)"

echo "════ docs truth fail=$fail ════"
[ "$fail" -eq 0 ]
