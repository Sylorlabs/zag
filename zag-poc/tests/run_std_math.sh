#!/usr/bin/env bash
# std:math accuracy gate in both editions.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZNC_BIN="${ZNC:-$ROOT/znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$ROOT/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-std-math.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
for edition in 2026 2027; do
    d="$WORK/e$edition"; mkdir -p "$d"
    printf 'name = "std-math"\nversion = "0"\nedition = "%s"\n' "$edition" >"$d/zag.mod"
    cp "$ROOT/tests/std_math.zag" "$d/main.zag"
    if (cd "$d" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$d/log" 2>&1; then
        (cd "$d" && ./out); rc=$?
        if [ "$rc" -eq 42 ]; then echo "  ok  std:math edition $edition"; pass=$((pass+1));
        else echo "  XX  std:math edition $edition failed check $rc"; fail=$((fail+1)); fi
    else
        echo "  XX  std:math edition $edition compile"; sed -n '1,12p' "$d/log"; fail=$((fail+1))
    fi
done
echo "std math: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
