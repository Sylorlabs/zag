#!/usr/bin/env bash
# Indentation-form ZagScript: assignment to an outer binding inside a while
# body must update that binding (it used to be rewritten into a shadowing
# `let`, which looped forever). Guarded by a timeout.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZNC_BIN="${ZNC:-$ROOT/znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$ROOT/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-zs-loop.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
cat >"$WORK/loop.zs" <<'EOF'
let numbers = list(1, 2, 3)
let total = 0
let i = 0
while i < length(numbers):
    total = total + item_at(numbers, i)
    i = i + 1
println(total)
return 0
EOF
if (cd "$WORK" && "$ZNC_BIN" script loop.zs -o loop --no-zagd --no-analyze) >"$WORK/log" 2>&1; then
    out=$(timeout 10 "$WORK/loop"); rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "6" ]; then echo "  ok  .zs while-body assignment updates the outer binding"; exit 0; fi
    echo "  XX  .zs while-body assignment rc=$rc out=[$out]"; exit 1
fi
echo "  XX  .zs loop compile"; sed -n '1,12p' "$WORK/log"; exit 1
