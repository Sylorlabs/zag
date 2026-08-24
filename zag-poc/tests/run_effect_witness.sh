#!/usr/bin/env bash
# Complete, human-readable E0002 effect-path regressions.
set -uo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh

ZNC="${ZNC:-$(zag_native_compiler "$PWD")}"
if [ ! -x "$ZNC" ]; then
    echo "run_effect_witness: $ZNC not found or not executable" >&2
    exit 1
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-effect-witness.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
case_id=0

check_path() {
    local label="$1" file="$2" expected="$3"
    local out rc artifact
    artifact="$tmp/out-$case_id"
    case_id=$((case_id + 1))
    out="$("$ZNC" "$file" -o "$artifact" --no-zagd --no-analyze 2>&1)"
    rc=$?
    if [ "$rc" -eq 1 ] && [ ! -e "$artifact" ] && printf '%s\n' "$out" | grep -Fq -- "$expected"; then
        echo "  ok    $label"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label (exit $rc, artifact=$([ -e "$artifact" ] && echo yes || echo no), missing: $expected)"
        printf '%s\n' "$out" | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

check_path "direct transitive chain" examples/audio_render_bad.zag \
    "renderBlock -> gain -> reverbScratch -> zalloc() [Alloc]"
check_path "generic callback binding" examples/process_poly_bad.zag \
    "renderBad -> processBlock -> op (callback=fancyOp) -> fancyOp -> zalloc() [Alloc]"
check_path "closure effect-variable binding" tests/effect_witness/v2_closure/main.zag \
    "closureCaller -> applyTwice -> op (callback=closure@6) -> closure@6 -> zalloc() [Alloc]"
check_path "closure terminal" tests/effect_witness/v2_closure/main.zag \
    "-> closure@6 -> zalloc() [Alloc]"
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
