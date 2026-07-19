#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
opt="$root/selfhost/native/optimize.zag"
ra="$root/selfhost/native/regalloc.zag"
ph="$root/selfhost/native/peephole.zag"
znc="$root/selfhost/native/znc.zag"

fail() { echo "FAIL optimizer-memory: $*" >&2; exit 1; }

# Breakers are common in compiler-sized programs. Replacing either symbolic
# stack there leaks the old backing allocation and makes retained memory grow
# with control-flow count.
if grep -Eq 'stk[[:space:]]*=[[:space:]]*make\[|ms_(tag|val)[[:space:]]*=[[:space:]]*make\[' "$opt"; then
    fail "control-flow reset allocates a replacement stack"
fi

grep -q 'free\[i32\](&matched)' "$opt" || fail "matched analysis buffer is not released"
grep -q 'free\[Instr\](&folded)' "$opt" || fail "folded instruction generation is not released"
grep -q 'free\[i32\](&cands)' "$ra" || fail "regalloc candidate buffers are not released"
grep -q 'if (owns_cur == 1) { free\[Instr\](&cur); }' "$ph" || fail "peephole fixpoint generations are retained"
grep -q 'free\[Instr\](&prog2)' "$znc" || fail "foreground regalloc generation is retained"
grep -q 'free\[Instr\](&prog3)' "$znc" || fail "foreground optimizer generation is retained"
grep -q 'free\[Instr\](&opt)' "$znc" || fail "foreground peephole generation is retained"

echo "optimizer memory hygiene: PASS"
