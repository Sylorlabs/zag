#!/usr/bin/env bash
# Differential gate: every tests/differential/*.zag must produce IDENTICAL
# stdout + exit code on the x86-64 and arm64 backends (arm64 via qemu-user).
# Divergence means one backend miscompiles — this is how the capture-less
# closure ABI bug, the >6-arg indirect-call bug, and the optional-coercion
# gaps were found. Requires qemu-aarch64-static.
cd "$(dirname "$0")/.."
QEMU="${QEMU:-qemu-aarch64-static}"
if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "  XX  $QEMU not found (apt install qemu-user-static)"; exit 1
fi
if [ -z "${ZNC:-}" ]; then
    if ! ./znc selfhost/native/znc.zag -o /tmp/znc_diff >/tmp/zd_build 2>&1; then
        echo "  XX  znc driver build"; sed -n '1,10p' /tmp/zd_build; exit 1
    fi
    ZNC=/tmp/znc_diff
fi
pass=0; fail=0
echo "── differential: x86-64 vs arm64 (identical output required) ──"
for f in tests/differential/t*.zag; do
    n=$(basename "$f" .zag)
    if ! "$ZNC" "$f" -o /tmp/dx86 >/tmp/dx86.log 2>&1; then
        echo "  XX  $n (x86 compile failed)"; sed -n '1,3p' /tmp/dx86.log; fail=$((fail+1)); continue
    fi
    ox=$(/tmp/dx86 2>&1); ex=$?
    if ! "$ZNC" "$f" --target arm64 -o /tmp/darm >/tmp/darm.log 2>&1; then
        echo "  XX  $n (arm64 compile failed)"; sed -n '1,3p' /tmp/darm.log; fail=$((fail+1)); continue
    fi
    oa=$("$QEMU" /tmp/darm 2>&1); ea=$?
    if [ "$ox" = "$oa" ] && [ "$ex" = "$ea" ]; then
        echo "  ok  $n (exit $ex)"; pass=$((pass+1))
    else
        echo "  XX  $n DIVERGES: x86(exit=$ex) arm(exit=$ea)"; fail=$((fail+1))
    fi
    rm -f /tmp/dx86 /tmp/darm
done
echo "════ differential pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
