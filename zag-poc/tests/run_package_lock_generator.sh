#!/usr/bin/env bash
set -u

repo=$(cd "$(dirname "$0")/.." && pwd)
znc=${ZNC:-$repo/znc}
case "$znc" in
    /*) ;;
    *) znc="$repo/${znc#./}" ;;
esac
fixture="$repo/tests/package_resolution/workspace/vendor_consumer"
expected="$fixture/zag.lock"
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-lock-generator.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

if [ ! -x "$znc" ]; then
    printf 'package lock generator: compiler is missing or not executable: %s\n' "$znc" >&2
    exit 2
fi

vendor="$work/vendor_consumer"
cp -R "$fixture" "$vendor"
rm "$vendor/zag.lock"

if (cd "$vendor" && "$znc" package lock src/main.zag \
        --no-zagd --no-analyze --no-foreground-cache) >"$work/generate.log" 2>&1 &&
    cmp -s "$vendor/zag.lock" "$expected"; then
    ok 'create-only generator emits canonical sorted lock entries before a lock exists'
else
    bad 'create-only generator emits canonical sorted lock entries before a lock exists'
    sed -n '1,20p' "$work/generate.log"
fi

before=$(sha256sum "$vendor/zag.lock" 2>/dev/null | awk '{print $1}')
if (cd "$vendor" && "$znc" package lock src/main.zag \
        --no-zagd --no-analyze --no-foreground-cache) >"$work/replace.log" 2>&1; then
    bad 'generator refuses to replace an existing lockfile'
else
    after=$(sha256sum "$vendor/zag.lock" 2>/dev/null | awk '{print $1}')
    if [ -n "$before" ] && [ "$before" = "$after" ] &&
        grep -F -q 'refusing to replace existing lock' "$work/replace.log"; then
        ok 'generator refuses to replace an existing lockfile'
    else
        bad 'generator refuses to replace an existing lockfile'
        sed -n '1,12p' "$work/replace.log"
    fi
fi

consumer="$work/consumer"
cp -R "$repo/tests/package_resolution/workspace/consumer" "$consumer"
cp -R "$repo/tests/package_resolution/workspace/toolkit" "$work/toolkit"
if (cd "$consumer" && "$znc" package lock src/main.zag \
        --no-zagd --no-analyze --no-foreground-cache) >"$work/nonvendor.log" 2>&1; then
    bad 'generator rejects an unlocked sibling dependency'
elif grep -F -q 'dependency must be mode=vendor' "$work/nonvendor.log"; then
    ok 'generator rejects an unlocked sibling dependency'
else
    bad 'generator rejects an unlocked sibling dependency'
    sed -n '1,12p' "$work/nonvendor.log"
fi

mutated="$work/mutated"
cp -R "$fixture" "$mutated"
rm "$mutated/zag.lock"
printf '\n' >>"$mutated/vendor/toolkit/src/toolkit.zag"
if (cd "$mutated" && "$znc" package lock src/main.zag \
        --no-zagd --no-analyze --no-foreground-cache) >"$work/mutated.log" 2>&1 &&
    ! cmp -s "$mutated/zag.lock" "$expected"; then
    ok 'generated checksum changes when vendored module bytes change'
else
    bad 'generated checksum changes when vendored module bytes change'
    sed -n '1,16p' "$work/mutated.log"
fi

printf 'Package lock generator: pass=%s fail=%s\n' "$pass" "$fail"
test "$fail" -eq 0
