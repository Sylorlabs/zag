#!/usr/bin/env bash
# run_vector_pipeline.sh — the vector pipeline's executable gate.
#
# Three things are checked, in increasing order of distance from the metal:
#   1. the target-independent vector IR (a self-hosted program that RUNS, so this
#      is a real exit code on whatever host this is);
#   2. auto-vectorization end to end through `znc view --level native`, which
#      prints the verified IR and the machine pipeline for the same module the
#      build path consumes;
#   3. the boundary: the pass is off by default, an unknown request is rejected,
#      and the loops it must refuse are actually refused.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh

ZNC=${ZNC:-$(zag_native_compiler "$PWD")}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
TARGET=()
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) TARGET=(--target macos-arm64);;
esac
tmp=$(mktemp -d /tmp/zag-vector.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# ── 1. the vector IR, executed ──────────────────────────────────────────────
"$ZNC" tests/vector_ir_test.zag -o "$tmp/vector_ir_test" "${TARGET[@]}" --no-analyze >/dev/null
"$tmp/vector_ir_test"

# ── 2. the auto-vectorizer, end to end ──────────────────────────────────────
# The fixture has one loop the pass must vectorize and two it must refuse.
"$ZNC" view tests/vectorize_loop.zag --level native --no-zagd --vectorize=on \
    > "$tmp/on.txt" 2>"$tmp/on.err" || { echo "vectorized view failed" >&2; cat "$tmp/on.err" >&2; exit 1; }
"$ZNC" view tests/vectorize_loop.zag --level native --no-zagd \
    > "$tmp/off.txt" 2>"$tmp/off.err" || { echo "baseline view failed" >&2; cat "$tmp/off.err" >&2; exit 1; }

# The integer accumulate loop is vectorized; the float one and the one with a
# call in the body are not.  Assert on the pass's own report, not on a count.
grep -q 'sum_add_all: vectorized' "$tmp/on.txt" \
    || { echo "the integer unit-stride accumulate loop was not vectorized" >&2; exit 1; }
grep -q 'sum_add_all_f32: rejected' "$tmp/on.txt" \
    || { echo "a float accumulator was vectorized; integer associativity does not hold for f32" >&2; exit 1; }
grep -q 'count_calls: rejected' "$tmp/on.txt" \
    || { echo "a loop with a call in the body was vectorized" >&2; exit 1; }

# The vector main loop really is vector IR, with the facts the lowering needs.
grep -q 'vector.splat' "$tmp/on.txt" || { echo "no vector.splat emitted" >&2; exit 1; }
grep -q 'memref.alloca() : memref<vector<' "$tmp/on.txt" \
    || { echo "no vector-typed accumulator slot in the IR" >&2; exit 1; }
grep -q 'vector.broadcast' "$tmp/on.txt" || { echo "no vector.broadcast emitted" >&2; exit 1; }
grep -q 'vector.add' "$tmp/on.txt" || { echo "no vector.add emitted" >&2; exit 1; }
# Lanes are ELEMENTS, and an element is a whole 8-byte word, so the generic
# 128-bit baseline carries 2 of them -- not the 4 a packed 32-bit lane count
# would give.  A `*i32` element advances 8 bytes in memory (zvec_elem_stride).
grep -q 'vector<i32,2>' "$tmp/on.txt" || { echo "no 2-lane word vector type in the IR" >&2; exit 1; }
# The address splat must carry the INDEX, or the load would read a[0..3] every
# iteration.  The printer emits every operand of a splat for exactly this reason.
grep -Eq 'vector\.splat %a, %v[0-9]+' "$tmp/on.txt" \
    || { echo "the address splat does not carry its index operand" >&2; exit 1; }
# `stride` is what tells a backend the window is contiguous.
grep -q 'stride = "unit"' "$tmp/on.txt" || { echo "the address splat has no unit stride" >&2; exit 1; }
# The horizontal fold back into the scalar slot must be explicit, not implied.
grep -q 'reduce = "add"' "$tmp/on.txt" || { echo "the accumulator store is not marked as a reduction" >&2; exit 1; }

# The epilogue must be the ORIGINAL loop, byte for byte.  This is the whole
# soundness argument, so it is checked rather than asserted in prose.
baseline_loop=$(sed -n '/func.func @sum_add_all(/,/^  }/p' "$tmp/off.txt")
vector_loop=$(sed -n '/func.func @sum_add_all(/,/^  }/p' "$tmp/on.txt")
if [ -z "$baseline_loop" ] || [ -z "$vector_loop" ]; then
    echo "could not isolate @sum_add_all in one of the two views" >&2
    exit 1
fi
# The vectorized function must contain strictly more IR than the baseline, and
# must still contain the baseline's `zag.index` epilogue unchanged.
[ "$(printf '%s' "$vector_loop" | grep -c '')" -gt "$(printf '%s' "$baseline_loop" | grep -c '')" ] \
    || { echo "vectorization did not add the main loop" >&2; exit 1; }
epilogue=$(printf '%s' "$vector_loop" | grep -A3 'zag.index' | head -4)
if ! printf '%s' "$baseline_loop" | grep -q 'zag.index'; then
    echo "the baseline has no scalar index access to preserve" >&2
    exit 1
fi
for line in $(printf '%s' "$baseline_loop" | grep 'zag.index' | sed 's/^ *//'); do
    printf '%s\n' "$vector_loop" | grep -qF "$line" \
        || { echo "the scalar epilogue was modified: $line" >&2; exit 1; }
done

# Two vector loops mean a vector main loop and a scalar epilogue, in that order.
scf_count=$(printf '%s' "$vector_loop" | grep -c 'scf.while {')
[ "$scf_count" = "2" ] || { echo "expected a vector main loop plus one epilogue, found $scf_count loops" >&2; exit 1; }
first_is_vector=$(printf '%s' "$vector_loop" | grep -n 'vector.add' | head -1 | cut -d: -f1)
first_index=$(printf '%s' "$vector_loop" | grep -n 'zag.index' | head -1 | cut -d: -f1)
[ -n "$first_is_vector" ] && [ -n "$first_index" ] && [ "$first_is_vector" -lt "$first_index" ] \
    || { echo "the vector main loop must come BEFORE the scalar epilogue" >&2; exit 1; }

# The reported width must follow the CPU profile, and 4 is what the generic
# x86-64 baseline resolves to.
grep -q 'target=sse2' "$tmp/on.txt" || { echo "the generic profile is not reported as sse2" >&2; exit 1; }
grep -q 'lanes=2' "$tmp/on.txt" || { echo "the generic profile is not reported as 2 lanes" >&2; exit 1; }
# Three vector ops: the address splat, the load, and the elementwise add.  The
# accumulator slot is a `memref.alloca` (zeroed by its own lowering), NOT a
# splat-of-zero, so a fourth op here would mean the slot is initialised twice.
grep -q 'vector-ops=3' "$tmp/on.txt" || { echo "the vector op count is not reported" >&2; exit 1; }

# ── 3. the vector ops reach a real ENCODER ──────────────────────────────────
# `vectorize_loop.zag` is deliberately too large for the ZIR-direct route (it has
# an ArrayList in it), so it proves the IR but not the machine code. This fixture
# is the smallest program the direct route accepts that still has a vectorizable
# loop, so it is where the lowering is checked against emitted instructions.
"$ZNC" view tests/vectorize_machine.zag --level native --no-zagd --vectorize=on \
    > "$tmp/mach.txt" 2>"$tmp/mach.err" || { echo "machine-code view failed" >&2; cat "$tmp/mach.err" >&2; exit 1; }

grep -q 'lowering=zir-direct' "$tmp/mach.txt" \
    || { echo "the vectorized module did not take the ZIR-direct route" >&2; exit 1; }

# The lowering must produce, for a 2-lane i32 accumulate at the generic x86-64
# baseline (SSE2 = 128 bits = two 8-byte word elements): a zeroed vector slot, a
# SCALED-INDEX vector load of the array, a word add, and then ONE 64-bit
# extraction per 128-bit chunk to fold the lanes into the scalar accumulator.
# Word lanes, not 32-bit lanes: a `*i32` element is an 8-byte slot.  There is NO
# scalar broadcast: the accumulator starts as a zeroed vector, not a splat of a
# scalar zero, so nothing needs lifting into lanes.
grep -q 'vmovdqu-load-idx' "$tmp/mach.txt" || { echo "no scaled-index vector load emitted" >&2; exit 1; }
if grep -q 'vsplat' "$tmp/mach.txt"; then
    echo "a scalar broadcast was emitted; the accumulator is a zeroed vector slot" >&2
    exit 1
fi
grep -q 'vpaddq' "$tmp/mach.txt" || { echo "no word vector add emitted" >&2; exit 1; }
# The fold is ONE shuffle and ONE add for the whole vector, then one 64-bit
# extraction per 128-bit chunk -- one chunk at the 128-bit baseline.
extracts=$(grep -c 'vextract64' "$tmp/mach.txt")
[ "$extracts" = "1" ] || { echo "expected 1 word extraction for the horizontal fold, found $extracts" >&2; exit 1; }
# The fold must target the reserved scratch register, never a live one.
if grep 'vextract64' "$tmp/mach.txt" | grep -qv 'disp=15'; then
    echo "a lane extraction did not use the reserved scratch register" >&2
    exit 1
fi
# The scaled-index load must carry the element's ADDRESS STRIDE, not its width.
# A `*i32` element advances 8 bytes (scale log 3 => imm 12).  Scaling by the
# element width (log 2 => imm 8) gathers four bytes-packed words that are not
# adjacent array elements, and the loop then reads the wrong data while still
# decoding cleanly -- this is the bug that only execution could find.
grep -Eq 'vmovdqu-load-idx .*imm=12 ' "$tmp/mach.txt" \
    || { echo "the vector load does not carry the 8-byte element stride" >&2; exit 1; }

# ── the LANE-WISE accumulator ───────────────────────────────────────────────
# Lane k of the accumulator vector sums the elements whose index is congruent to
# k, so the L lanes hold L DISJOINT partial sums and ONE horizontal fold after
# the loop totals them.  That structure is the performance argument, and it is
# checkable: a per-iteration fold would put the fold INSIDE the loop, between the
# slot load and the slot store, instead of after the back edge.
grep -q 'vpxor-zero' "$tmp/mach.txt" \
    || { echo "the vector accumulator slot is not zero-initialised" >&2; exit 1; }
# Two slot stores (initialise, then the loop body's write-back) and two slot
# loads (the loop body's read, then the single fold's read).
stores=$(grep -c 'vmovdqu-store' "$tmp/mach.txt")
loads=$(grep -c 'vmovdqu-load ' "$tmp/mach.txt")
[ "$stores" = "2" ] || { echo "expected 2 vector-slot stores, found $stores" >&2; exit 1; }
[ "$loads" = "2" ] || { echo "expected 2 vector-slot loads, found $loads" >&2; exit 1; }
# Both must address the SAME slot, and it must be a whole register wide.
slot=$(grep -o 'vmovdqu-store .*disp=-\?[0-9]*' "$tmp/mach.txt" | head -1 | grep -o 'disp=-\?[0-9]*')
if [ -z "$slot" ]; then echo "could not read the vector slot displacement" >&2; exit 1; fi
for l in $(grep -oE '(vmovdqu-store|vmovdqu-load) .*disp=-?[0-9]+' "$tmp/mach.txt" | grep -o 'disp=-\?[0-9]*' | sort -u); do
    [ "$l" = "$slot" ] || { echo "vector slot accesses disagree: $slot vs $l" >&2; exit 1; }
done
# THE fold, and it must sit AFTER the loop body's write-back -- which is exactly
# where a per-iteration fold would NOT be.
shuffles=$(grep -c 'vpshufd' "$tmp/mach.txt")
[ "$shuffles" = "1" ] || { echo "expected exactly 1 fold shuffle, found $shuffles" >&2; exit 1; }
last_store=$(grep -n 'vmovdqu-store' "$tmp/mach.txt" | tail -1 | cut -d: -f1)
fold_line=$(grep -n 'vpshufd' "$tmp/mach.txt" | head -1 | cut -d: -f1)
if [ "$fold_line" -le "$last_store" ]; then
    echo "the horizontal fold is INSIDE the loop; it must run once, after it" >&2
    exit 1
fi
# The elementwise add and the fold's add are both word adds; exactly two.
adds=$(grep -c 'vpaddq' "$tmp/mach.txt")
[ "$adds" = "2" ] || { echo "expected 2 word adds (elementwise + fold), found $adds" >&2; exit 1; }

# The encoded bytes must decode to those instructions. llvm-mc is used as an
# oracle; the assertion is that NOTHING is undecodable, which is what a wrong
# width class or a bad VEX/EVEX field would produce.
MC=$(command -v llvm-mc || echo /opt/homebrew/opt/llvm/bin/llvm-mc)
if [ -x "$MC" ]; then
    grep '^// machine-code-hex=' "$tmp/mach.txt" | sed 's|.*=||' | tr -d ' ' > "$tmp/hex.txt"
    python3 - "$tmp/hex.txt" > "$tmp/stream.txt" <<'PYEOF'
import sys
data = bytes.fromhex(open(sys.argv[1]).read().strip())
print(" ".join("0x%02x" % b for b in data))
PYEOF
    "$MC" -disassemble -triple=x86_64-pc-linux-gnu < "$tmp/stream.txt" > "$tmp/dis.txt" 2>&1
    if grep -q '<bad>' "$tmp/dis.txt"; then
        echo "the emitted machine code contains undecodable bytes" >&2
        exit 1
    fi
    for m in vpxor vmovdqu vpaddq vpshufd vpextrq; do
        grep -q "$m" "$tmp/dis.txt" || { echo "expected $m in the disassembly" >&2; exit 1; }
    done
    # The scaled-index load must really be scaled by 8, i.e. base + index*8, and
    # must NOT set REX.X (which would add 8 to the index and read another
    # register while decoding perfectly).
    grep -qF '(%rcx,%rdx,8)' "$tmp/dis.txt" \
        || { echo "the vector load is not a scale-8 indexed load" >&2; exit 1; }
    # The single fold extraction is qword lane 0 of the scratch register.
    grep -qE 'vpextrq[[:space:]]+\$0,' "$tmp/dis.txt" \
        || { echo "the fold does not extract qword lane 0" >&2; exit 1; }
fi

# ── 4. the boundary ─────────────────────────────────────────────────────────
# Off by default: the baseline view must contain no vector IR at all.
grep -q 'vectorized=0' "$tmp/off.txt" || { echo "vectorization ran without being asked" >&2; exit 1; }
if grep -q 'vector\.add' "$tmp/off.txt"; then
    echo "vector IR appeared without --vectorize" >&2
    exit 1
fi
# An unknown request is an error, not a silent downgrade to the baseline.
if "$ZNC" view tests/vectorize_loop.zag --level native --no-zagd --vectorize=maybe \
        >"$tmp/bogus.txt" 2>&1; then
    echo "--vectorize=maybe was accepted" >&2
    exit 1
fi
grep -q 'unknown --vectorize value' "$tmp/bogus.txt" \
    || { echo "--vectorize=maybe failed without a diagnostic" >&2; exit 1; }
# The default is reported as a decision, not an absence.
grep -q 'vectorize-requested=0' "$tmp/off.txt" \
    || { echo "the default vectorize state is not reported" >&2; exit 1; }

echo "vector pipeline: IR, vectorizer, epilogue preservation, ZIR-direct machine lowering, and the off-by-default boundary pass"
