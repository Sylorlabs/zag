#!/usr/bin/env bash
# TNN arena authority: exact 250 MiB accounting, recovery reserve, checked
# word/bulk access, cursor-stable OOM, reset generations, and metadata reuse.
set -eu
cd "$(dirname "$0")/.."

ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac

tmp=$(mktemp -d /tmp/zag-arena-telemetry.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/project"
cp tests/arena_telemetry.zag "$tmp/project/main.zag"
ln -s "$PWD/selfhost/std" "$tmp/project/std"
printf 'name = "arena_telemetry"\nversion = "0"\nedition = "2027"\n' >"$tmp/project/zag.mod"

pass=0
fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

echo '── TNN 250 MiB retained-arena authority ──'
if (cd "$tmp/project" && "$ZNC" main.zag -o arena-test --safety=checked --no-zagd) >"$tmp/positive.log" 2>&1 &&
   [ -x "$tmp/project/arena-test" ]; then
    set +e
    "$tmp/project/arena-test"
    rc=$?
    set -e
    if [ "$rc" -eq 42 ]; then
        ok 'exact capacity, 80% pressure, OOM stability, reset, bulk access, and churn'
    else
        bad "arena telemetry execution returned $rc"
        sed -n '1,24p' "$tmp/positive.log"
    fi
else
    bad 'arena telemetry authority did not compile'
    sed -n '1,24p' "$tmp/positive.log"
fi

reject_case() {
    fixture=$1
    needle=$2
    label=$3
    cp "tests/$fixture.zag" "$tmp/project/main.zag"
    rm -f "$tmp/project/rejected"
    if (cd "$tmp/project" && "$ZNC" main.zag -o rejected --safety=checked --no-zagd) >"$tmp/$fixture.log" 2>&1 ||
       [ -e "$tmp/project/rejected" ]; then
        bad "$label compiled or left an artifact"
        sed -n '1,18p' "$tmp/$fixture.log"
    elif grep -q "$needle" "$tmp/$fixture.log"; then
        ok "$label"
    else
        bad "$label lacked its ownership diagnostic"
        sed -n '1,18p' "$tmp/$fixture.log"
    fi
}

reject_case arena_telemetry_stale 'retained reads require one live named block' \
    'stale word borrowing fails before execution'
reject_case arena_telemetry_alias 'retained backing, allocator, and blocks cannot be copied' \
    'block aliases fail before execution'
reject_case arena_telemetry_wrong_receiver 'arena telemetry requires the live ArenaAllocator' \
    'telemetry cannot cross allocator capability types'

echo "════ arena-telemetry pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
