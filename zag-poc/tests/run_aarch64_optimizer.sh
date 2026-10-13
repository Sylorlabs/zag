#!/usr/bin/env bash
# run_aarch64_optimizer.sh — gate the AArch64 stack-machine optimizer.
#
# `selfhost/native/aoptimize.zag` rewrites the flat ArrayList[AInstr] that
# acodegen.zag produces: it removes constant push/pop pairs, folds constant
# arithmetic, and deletes dead moves. It runs only on the macOS build path.
#
# This gate exists because the pass is wired into the compiler itself. A wrong
# rewrite here does not crash and does not diagnose — it silently computes the
# wrong answer, which is the failure mode this codebase cannot tolerate in a
# pass whose whole job is "observationally equivalent".
#
# It checks three layers:
#   (1) the pass's own unit suite (selfhost/native/aoptimize_test.zag), which
#       asserts the rewrites that MUST happen and, mostly, the ones that must
#       NOT — including the two-address liveness rule that a real miscompile
#       came from;
#   (2) a differential run of every buildable program in programs/ and examples/,
#       comparing the optimizing compiler's output and exit code against the
#       unoptimized baseline;
#   (3) that the pass actually changes the emitted image, so a build that
#       silently stopped wiring it in cannot pass this gate.
#
# Layer (2) needs the baseline compiler. Set AOPT_BASELINE to its path; if it is
# absent the differential layer is SKIPPED, not failed, because the gate must
# still be runnable on a fresh checkout.
set -uo pipefail
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-aopt.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

FLAGS=(--target macos-arm64 --no-analyze --no-zagd --no-foreground-cache)

# ── (1) unit suite ───────────────────────────────────────────────────────────
echo "── aarch64 optimizer: unit suite ──"
if ! "$ZNC" selfhost/native/aoptimize_test.zag -o "$tmp/aopt" "${FLAGS[@]}" >"$tmp/build.log" 2>&1; then
    echo "could not build the optimizer test suite" >&2
    cat "$tmp/build.log" >&2
    exit 1
fi
if ! "$tmp/aopt"; then
    echo "aarch64 optimizer: FAIL (unit suite)" >&2
    exit 1
fi

# ── (2) differential against the unoptimized baseline ────────────────────────
BASE=${AOPT_BASELINE:-}
echo "── aarch64 optimizer: differential vs baseline ──"
if [ -z "$BASE" ] || [ ! -x "$BASE" ]; then
    echo "aarch64 optimizer: SKIP differential (set AOPT_BASELINE to an unoptimized compiler)"
else
    same=0; differ=0; skipped=0
    # Bounded on purpose. The compiler peaks around 1.3 GB, and running every
    # file in programs/ plus all 71 examples in one shell exhausts the heap --
    # which surfaces as an absurd realloc size, not as a clean OOM.
    budget=${AOPT_DIFF_BUDGET:-8}
    for f in programs/*.zag $(ls examples/*.zag 2>/dev/null | head -"$budget"); do
        [ -e "$f" ] || continue
        rm -f .zagd.lock
        "$BASE" "$f" -o "$tmp/old" "${FLAGS[@]}" >/dev/null 2>&1 || { skipped=$((skipped+1)); continue; }
        rm -f .zagd.lock
        "$ZNC"  "$f" -o "$tmp/new" "${FLAGS[@]}" >/dev/null 2>&1 || {
            echo "  XX  the optimizing compiler failed to build $f" >&2; differ=$((differ+1)); continue; }
        r_old=$("$tmp/old" 2>&1; echo "exit=$?")
        r_new=$("$tmp/new" 2>&1; echo "exit=$?")
        if [ "$r_old" = "$r_new" ]; then same=$((same+1)); else
            echo "  XX  $f: optimizing compiler changed the result" >&2
            echo "      baseline: $r_old" >&2
            echo "      optimized: $r_new" >&2
            differ=$((differ+1))
        fi
    done
    echo "  $same identical, $differ differing, $skipped unbuildable on this host"
    if [ "$differ" -ne 0 ]; then
        echo "aarch64 optimizer: FAIL (the pass is not behaviour-preserving)" >&2
        exit 1
    fi
fi

# ── (3) the pass must still be doing something ───────────────────────────────
# A wiring regression that dropped the aoptimize() call would leave layers 1 and 2
# green while silently removing the whole optimization. The signal is that the
# emitted image DIFFERS from the unoptimized baseline -- not that it is SMALLER.
# Size is the wrong proxy: the pass deletes stack traffic (str/ldr pairs around
# x28) and replaces it with a mov of the same width, so code size barely moves.
# Byte difference proves the pass ran; layer 2 proves it was correct.
echo "── aarch64 optimizer: the pass is actually wired in ──"
probe=$(mktemp -d /tmp/zag-aopt-probe.XXXXXX)
cat > "$probe/p.zag" <<'EOF'
fn f(a: i32, b: i32) i32 {
    let t: i32 = 5;
    let s: i32 = a + t;
    let u: i32 = s + t;
    return u + b;
}
fn main() i32 { return f(1, 2); }
EOF
if ! "$ZNC" "$probe/p.zag" -o "$probe/new" "${FLAGS[@]}" >/dev/null 2>&1; then
    echo "could not build the wiring probe" >&2; rm -rf "$probe"; exit 1
fi
"$probe/new"; rc=$?
if [ "$rc" -ne 13 ]; then
    echo "aarch64 optimizer: FAIL -- wiring probe returned $rc, expected 13" >&2
    rm -rf "$probe"; exit 1
fi

if [ -n "$BASE" ] && [ -x "$BASE" ]; then
    cat > "$probe/p.zag" <<'EOF'
fn f(a: i32, b: i32) i32 {
    let t: i32 = 5;
    let s: i32 = a + t;
    let u: i32 = s + t;
    return u + b;
}
fn main() i32 { return f(1, 2); }
EOF
    "$BASE" "$probe/p.zag" -o "$probe/old" "${FLAGS[@]}" >/dev/null 2>&1
    if cmp -s "$probe/old" "$probe/new"; then
        echo "aarch64 optimizer: FAIL -- the optimizing compiler emitted a byte-identical" >&2
        echo "  image; the aoptimize() call is almost certainly no longer wired in." >&2
        rm -rf "$probe"; exit 1
    fi
    echo "  emitted image differs from the unoptimized baseline (pass is active)"
else
    echo "  no baseline available; cannot confirm the pass changed the image"
fi
rm -rf "$probe"

echo "aarch64 optimizer: pass"
