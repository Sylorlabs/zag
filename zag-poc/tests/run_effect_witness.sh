#!/usr/bin/env bash
# Complete, human-readable E0002 effect-path regressions.
set -uo pipefail
cd "$(dirname "$0")/.."

ZNC="${ZNC:-./znc}"
pass=0
fail=0

check_path() {
    local label="$1" file="$2" expected="$3"
    local out
    out="$($ZNC "$file" -o /tmp/zag-effect-witness --no-zagd --no-analyze 2>&1 || true)"
    if printf '%s\n' "$out" | grep -Fq -- "$expected"; then
        echo "  ok    $label"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label (missing: $expected)"
        printf '%s\n' "$out" | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

check_path "direct transitive chain" examples/audio_render_bad.zag \
    "renderBlock -> gain -> reverbScratch -> zalloc() [Alloc]"
check_path "generic callback binding" examples/process_poly_bad.zag \
    "renderBad -> processBlock -> op (callback=fancyOp) -> fancyOp -> zalloc() [Alloc]"
check_path "closure effect-variable binding" tests/effect_witness/v2_closure/main.zag \
    "closureCaller -> applyTwice -> op (callback=closure@"
check_path "closure terminal" tests/effect_witness/v2_closure/main.zag \
    "-> closure@"
check_path "imported source identity" tests/effect_witness/import_main.zag \
    "importedScratch [tests/effect_witness/import_alloc.zag:1] -> zalloc() [Alloc]"
check_path "recursive graph terminates with source" tests/effect_witness/recursive.zag \
    "recursiveCaller -> cycleA -> cycleB -> zalloc() [Alloc]"
check_path "all violated effects render allocation" tests/effect_witness/multiple.zag \
    "effect path [Alloc]: multipleSources -> zalloc() [Alloc]"
check_path "all violated effects render IO" tests/effect_witness/multiple.zag \
    "effect path [IO]: multipleSources -> print_str() [IO]"

echo "════ effect-witness pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
