#!/usr/bin/env bash
# tests/run_hot_reload.sh — end-to-end test for native live code hot-reload.
#
# Builds examples/hot_demo.zag with --hot, runs it, live-edits the swappable
# `label()` function (1 → 7, a layout-preserving change), stages a hot-patch,
# and asserts the running process swapped in the new code WITHOUT restarting —
# the printed leading digit flips from 1 to 7 while the loop counter keeps
# climbing. Also asserts a size-CHANGING edit is refused (no corruption).
#
# The ONLY supported compiler is ./znc (the native ELF backend).
# Exit: 0 = passed, 1 = failed.
set -uo pipefail
cd "$(dirname "$0")/.."

ZNC="${ZNC:-./znc}"
SRC="examples/hot_demo.zag"
WORK="$(mktemp -d)"
BIN="$WORK/hot_demo"
OUT="$WORK/out.txt"
PIDFILE="$WORK/pid"

pass=0
fail=0
note() { echo "  $*"; }

cleanup() {
    touch .zag_hotstop 2>/dev/null || true
    sleep 0.3
    if [ -f "$PIDFILE" ]; then kill -9 "$(cat "$PIDFILE")" 2>/dev/null || true; fi
    # restore the source and remove coordination files
    sed -i 's/^    return 7;$/    return 1;/' "$SRC" 2>/dev/null || true
    sed -i 's/^    print_i32(0); return 1;$/    return 1;/' "$SRC" 2>/dev/null || true
    rm -f .zag_hotstop .zag_hotpatch .zag_hotlen .zag_hotdlen
    rm -rf "$WORK"
}
trap cleanup EXIT

# make sure we start from the canonical source (label returns 1)
sed -i 's/^    return 7;$/    return 1;/' "$SRC" 2>/dev/null || true
rm -f .zag_hotstop .zag_hotpatch .zag_hotlen .zag_hotdlen

# ── build --hot ───────────────────────────────────────────────────────────────
if "$ZNC" build --hot "$SRC" -o "$BIN" >/dev/null 2>&1 && [ -x "$BIN" ] && [ -f .zag_hotlen ]; then
    note "ok    build --hot produced binary + .zag_hotlen"; pass=$((pass+1))
else
    note "FAIL  build --hot"; fail=$((fail+1)); echo "════ hot-reload pass=$pass fail=$fail ════"; exit 1
fi

# ── run it ────────────────────────────────────────────────────────────────────
( "$BIN" > "$OUT" 2>&1 & echo $! > "$PIDFILE" )
sleep 1.2
if grep -qE '^1[0-9][0-9][0-9]$' "$OUT"; then
    note "ok    running program prints 1xxx (label()==1)"; pass=$((pass+1))
else
    note "FAIL  no 1xxx output before patch"; note "$(cat "$OUT")"; fail=$((fail+1))
fi

# ── live edit + hot-patch ─────────────────────────────────────────────────────
sed -i 's/^    return 1;$/    return 7;/' "$SRC"
if "$ZNC" hot-patch "$SRC" 2>&1 | grep -q "staged"; then
    note "ok    hot-patch staged a layout-preserving edit"; pass=$((pass+1))
else
    note "FAIL  hot-patch did not stage"; fail=$((fail+1))
fi
sleep 1.2

# ── assert the live swap happened (7xxx appears, counter kept climbing) ────────
if grep -qE '^7[0-9][0-9][0-9]$' "$OUT"; then
    note "ok    LIVE SWAP: output flipped to 7xxx without restart ✓"; pass=$((pass+1))
else
    note "FAIL  code did not hot-swap (no 7xxx line)"; note "$(cat "$OUT")"; fail=$((fail+1))
fi
# continuity: the first 7xxx counter must be >= a seen 1xxx counter (state survived)
last1=$(grep -E '^1[0-9][0-9][0-9]$' "$OUT" | tail -1 | sed 's/^1//')
first7=$(grep -E '^7[0-9][0-9][0-9]$' "$OUT" | head -1 | sed 's/^7//')
if [ -n "$last1" ] && [ -n "$first7" ] && [ "$((10#$first7))" -ge "$((10#$last1))" ]; then
    note "ok    in-memory counter survived the swap ($((10#$last1)) → $((10#$first7)))"; pass=$((pass+1))
else
    note "FAIL  counter continuity (last1=$last1 first7=$first7)"; fail=$((fail+1))
fi

# ── stop cleanly ──────────────────────────────────────────────────────────────
touch .zag_hotstop
sleep 0.6
if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    note "ok    .zag_hotstop exits the loop cleanly"; pass=$((pass+1)); rm -f "$PIDFILE"
else
    note "FAIL  program did not stop on .zag_hotstop"; fail=$((fail+1))
fi

# ── layout guard: a size-changing edit must be refused ────────────────────────
# An IO call survives DCE and genuinely enlarges the compiled function (unlike a
# constant expression, which the optimizer would fold back to the same size).
sed -i 's/^    return 7;$/    print_i32(0); return 1;/' "$SRC"
guard_out="$("$ZNC" hot-patch "$SRC" 2>&1 || true)"   # rc=1 on refusal; capture, don't pipe
if printf '%s' "$guard_out" | grep -q "rebuild required" && [ ! -s .zag_hotpatch ]; then
    note "ok    size-changing edit refused (no corrupt patch)"; pass=$((pass+1))
else
    note "FAIL  layout guard did not refuse a size-changing edit"; fail=$((fail+1))
fi
sed -i 's/^    print_i32(0); return 1;$/    return 1;/' "$SRC"

echo "════ hot-reload pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
