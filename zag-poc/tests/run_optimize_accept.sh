#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-optimize-accept.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
check() {
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
}

i32="$PWD/tests/optimize_accept_i32.zag"
i32_neg="$PWD/tests/optimize_accept_i32_neg.zag"
i32_neg_min="$PWD/tests/optimize_accept_i32_neg_min.zag"
i64="$PWD/tests/optimize_accept_i64.zag"
i_bool="$PWD/tests/optimize_accept_bool.zag"
i32_before=$(sha256sum "$i32" | awk '{print $1}')
i32_neg_before=$(sha256sum "$i32_neg" | awk '{print $1}')
i64_before=$(sha256sum "$i64" | awk '{print $1}')
i_bool_before=$(sha256sum "$i_bool" | awk '{print $1}')

i32_out="$tmp/i32.out"
i32_neg_out="$tmp/i32-neg.out"
i64_out="$tmp/i64.out"
i_bool_out="$tmp/bool.out"
if "$ZNC" optimize --accept const-i32-add-v1 "$i32" -o "$i32_out" --no-zagd >"$tmp/i32.log" 2>&1 && test -x "$i32_out"; then
    set +e; "$i32_out"; i32_rc=$?; set -e
else
    i32_rc=1
fi
if test "${i32_rc:-1}" = 3; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi
if grep -q 'differential=baseline-exit-stdout-stderr' "$tmp/i32.log"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi
if "$ZNC" optimize --accept const-i32-neg-v1 "$i32_neg" -o "$i32_neg_out" --no-zagd >"$tmp/i32-neg.log" 2>&1 && test -x "$i32_neg_out"; then
    set +e; "$i32_neg_out"; i32_neg_rc=$?; set -e
else
    i32_neg_rc=1
fi
if test "${i32_neg_rc:-1}" = 249; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi
if grep -q 'differential=baseline-exit-stdout-stderr' "$tmp/i32-neg.log"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi
if "$ZNC" optimize --accept const-i64-add-v1 "$i64" -o "$i64_out" --no-zagd >"$tmp/i64.log" 2>&1 && test -x "$i64_out"; then
    set +e; "$i64_out"; i64_rc=$?; set -e
else
    i64_rc=1
fi
if test "${i64_rc:-1}" = 3; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi
if grep -q 'differential=baseline-exit-stdout-stderr' "$tmp/i64.log"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi
if "$ZNC" optimize --accept const-bool-cmp-v1 "$i_bool" -o "$i_bool_out" --no-zagd >"$tmp/bool.log" 2>&1 && test -x "$i_bool_out"; then
    set +e; "$i_bool_out"; i_bool_rc=$?; set -e
else
    i_bool_rc=1
fi
if test "${i_bool_rc:-1}" = 42; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi
if grep -q 'differential=baseline-exit-stdout-stderr' "$tmp/bool.log"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi

check test "$(sha256sum "$i32" | awk '{print $1}')" = "$i32_before"
check test "$(sha256sum "$i32_neg" | awk '{print $1}')" = "$i32_neg_before"
check test "$(sha256sum "$i64" | awk '{print $1}')" = "$i64_before"
check test "$(sha256sum "$i_bool" | awk '{print $1}')" = "$i_bool_before"

if "$ZNC" optimize --accept no-such-rule "$i32" -o "$tmp/bad.out" --no-zagd >"$tmp/bad.log" 2>&1; then
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi
check test ! -e "$tmp/bad.out"

printf 'foreign-artifact\n' >"$tmp/existing.out"
if "$ZNC" optimize --accept const-i32-add-v1 "$i32" -o "$tmp/existing.out" --no-zagd >"$tmp/existing.log" 2>&1; then
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi
check grep -qx 'foreign-artifact' "$tmp/existing.out"

# The reviewed handoff must keep the source snapshot alive across both child
# builds and check it again before publication. These are source-level
# invariants in addition to the differential runtime checks above.
check grep -q 'fn znc_optimize_accept_source_matches' selfhost/native/znc.zag
check grep -q 'source changed during baseline validation' selfhost/native/znc.zag
check grep -q 'source changed before reviewed publication' selfhost/native/znc.zag
check grep -q 'const-bool-cmp-v1' selfhost/native/znc.zag
check grep -q 'const-i32-neg-v1' selfhost/native/znc.zag
check grep -Eq 'record\.transform[[:space:]]*,[[:space:]]*rule' selfhost/native/znc.zag
check grep -q 'transform_identity' selfhost/zagd_daemon.zag
check grep -q 'transform=' selfhost/zagd_daemon.zag

# A daemon record is never optional once explicitly requested. Missing or
# stale evidence must fail closed before any foreground artifact is published.
if "$ZNC" optimize --accept const-i32-add-v1 "$i32" -o "$tmp/missing-evidence.out" --from-zagd --no-zagd >"$tmp/missing-evidence.log" 2>&1; then
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi
check test ! -e "$tmp/missing-evidence.out"
check grep -q -- '--from-zagd requires a current verified_best_measured' "$tmp/missing-evidence.log"

# Signed negation of i32 MIN_INT is not a defined i32 operation in this
# checked rule. The producer and source-policy checker must reject it before
# publishing any reviewed artifact.
if "$ZNC" optimize --accept const-i32-neg-v1 "$i32_neg_min" -o "$tmp/i32-neg-min.out" --no-zagd >"$tmp/i32-neg-min.log" 2>&1; then
    fail=$((fail + 1))
else
    pass=$((pass + 1))
fi
check test ! -e "$tmp/i32-neg-min.out"
check grep -Eq 'no checked source match|accepted rule failed foreground validation|source-context' "$tmp/i32-neg-min.log"

printf 'optimize accept: pass=%d fail=%d\n' "$pass" "$fail"
test "$fail" -eq 0
