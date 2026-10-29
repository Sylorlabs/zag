#!/usr/bin/env bash
# Zag has no unary `~`. Using it must give a front-end diagnostic (E0031) at the
# `~` token, not the old native "unknown identifier in expression: ~" / ": )"
# error. The documented replacement `x ^ -1` must compile and run. Both editions.
set -u
cd "$(dirname "$0")/.."
ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-tilde.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
build() { # $1 file $2 edition -> sets d; returns compile status
    d="$WORK/$(basename "$1" .zag)-$2"; mkdir -p "$d"
    printf 'name = "tilde"\nversion = "0"\nedition = "%s"\n' "$2" >"$d/zag.mod"
    cp "tests/tilde_diagnostic/$1" "$d/main.zag"
    (cd "$d" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$d/log" 2>&1
}
for ed in 2026 2027; do
    for pair in "tilde_bare.zag:3:18" "tilde_paren.zag:3:23"; do
        f="${pair%%:*}"; loc="${pair#*:}"
        if build "$f" "$ed"; then bad "$ed $f compiled (want E0031)"
        elif grep -q "unknown identifier" "$d/log"; then bad "$ed $f still reports unknown identifier"; head -5 "$d/log"
        elif grep -q "error\[E0031\]" "$d/log" && grep -qE -- "--> .*:$loc\$" "$d/log"; then ok "$ed $f rejected with E0031 at $loc"
        else bad "$ed $f wrong diagnostic"; head -8 "$d/log"; fi
    done
    if build xor_complement.zag "$ed"; then
        (cd "$d" && ./out); rc=$?
        if [ "$rc" -eq 0 ]; then ok "$ed x ^ -1 complement"; else bad "$ed xor_complement rc=$rc"; fi
    else bad "$ed xor_complement compile"; head -5 "$d/log"; fi
done
echo "tilde diagnostic: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
