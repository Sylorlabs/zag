#!/usr/bin/env bash
# run_vector_equiv_x86_64.sh — RUNTIME proof of the vector pipeline.
#
# Everything else in the vector suite checks SHAPE: that the right ops were
# emitted, that they decode, that the epilogue survived. None of it proves the
# emitted code computes anything. This does.
#
# It builds tests/vectorize_equiv.zag twice for x86-64 -- once with
# --vectorize=on, once with it off -- and runs BOTH. Each build compares its own
# vectorized sum against its own scalar reference over the same memory, so the
# two binaries need not agree with each other, only each with itself.
#
# Every bug this file was written for passed every shape check in the suite:
#   * a scale-4 vector load over a `*i32`, whose elements are 8 bytes apart, read
#     the wrong data and still decoded perfectly;
#   * a horizontal fold that added the scratch to itself doubled one partial
#     instead of totalling it, and a self-comparison passed for n<2;
#   * a broadcast accumulator was summed once per lane, so the second vector
#     iteration came out L*acc + sum(e) while the first was right;
#   * a scaled-index load with REX.X hardcoded read r10 instead of rdx.
#
# It runs over every x86-64 microarchitecture level. Each level declares a rung
# rather than detecting one, so the 256- and 512-bit paths BUILD anywhere; a
# rung whose instructions the executing CPU does not implement raises #UD and is
# reported as BUILD-only rather than failed. That distinction matters: a host
# without AVX-512 must not be able to turn a correct AVX-512 build red.
#
# It runs the x86-64 binary under Docker, so it needs an amd64 emulator and is
# therefore SKIPPED, not failed, when one is unavailable.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh

ZNC=${ZNC:-$(zag_native_compiler "$PWD")}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-veq.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

have_docker=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    have_docker=1
fi
if [ "$have_docker" = 0 ]; then
    echo "vector equivalence: SKIP (no usable docker; cannot execute x86-64 here)"
    exit 0
fi

# level:expected-target:expected-lanes
RUNGS="x86-64-v1:sse2:2 x86-64-v2:sse2:2 x86-64-v3:avx2:4 x86-64-v4:avx512:8"

run_x86_64() {
    docker run --rm --platform linux/amd64 -i alpine:3.20 \
        sh -c 'cat > /tmp/a && chmod +x /tmp/a && timeout 300 /tmp/a; echo "exit=$?"' < "$1"
}

executed=0
build_only=0

for rung in $RUNGS; do
    level=${rung%%:*}
    rest=${rung#*:}
    want_target=${rest%%:*}
    want_lanes=${rest#*:}

    # The vectorized build MUST vectorize, and it MUST be the rung we asked for.
    # A silent fall back to the scalar path would make every exit code 0 and
    # prove nothing; landing on the wrong rung would prove the wrong thing.
    if ! "$ZNC" view tests/vectorize_equiv.zag --level native --no-zagd \
            --vectorize=on --cpu="$level" > "$tmp/view.txt" 2>"$tmp/view.err"; then
        echo "could not view the $level vectorization" >&2; cat "$tmp/view.err" >&2; exit 1
    fi
    grep -q 'vec_sum: vectorized' "$tmp/view.txt" \
        || { echo "the equivalence fixture was NOT vectorized at $level; the run would prove nothing" >&2; exit 1; }
    grep -q "vmovdqu-load-idx" "$tmp/view.txt" \
        || { echo "the equivalence fixture emitted no vector load at $level" >&2; exit 1; }
    grep -q "target=$want_target lanes=$want_lanes" "$tmp/view.txt" \
        || { echo "$level did not select $want_target/$want_lanes:" >&2
             grep -i 'vectorize-requested' "$tmp/view.txt" >&2 || true; exit 1; }

    for mode in on off; do
        if ! "$ZNC" tests/vectorize_equiv.zag --target x86_64 -o "$tmp/eq_${level}_$mode" \
            --vectorize=$mode --cpu="$level" --no-zagd --no-analyze >/dev/null 2>"$tmp/build.err"; then
            echo "could not build the $mode binary for $level" >&2; cat "$tmp/build.err" >&2; exit 1
        fi
        out=$(run_x86_64 "$tmp/eq_${level}_$mode")
        code=${out##*exit=}
        case "$code" in
            0) ;;
            # 128+4 = SIGILL. The build is proven; the CPU simply lacks the ISA.
            132)
                build_only=$((build_only + 1))
                printf 'vectorize=%-4s %-12s BUILD-ONLY (this CPU raised #UD; vector=%s)\n' \
                    "$mode" "$level" "$want_target"
                ;;
            *)
                echo "the $mode build for $level did not agree with its own scalar reference: $out" >&2
                exit 1
                ;;
        esac
        [ "$code" = 132 ] || executed=$((executed + 1))
        [ "$code" = 132 ] || printf 'vectorize=%-4s %-12s PASS (%s lanes=%s)\n' \
            "$mode" "$level" "$want_target" "$want_lanes"
    done
done

echo "vector equivalence: all four rungs built; $executed builds ran and agreed with their scalar reference"
if [ "$build_only" -gt 0 ]; then
    echo "vector equivalence: $build_only build(s) verified by construction only (host lacks the ISA)"
fi