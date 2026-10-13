#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh

compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-map-explicit.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

printf '%s\n' 'name = "script-map-explicit-test"' 'edition = "2027"' >"$tmp/zag.mod"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp/.zagd.conf"
cp tests/script_map_literals.zag "$tmp/literals.zag"

"$compiler" "$tmp/literals.zag" -o "$tmp/compact" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/compact.compile.out" 2>"$tmp/compact.compile.err"
set +e
"$tmp/compact" >"$tmp/compact.out" 2>"$tmp/compact.err"
compact_status=$?
set -e

"$compiler" expand "$tmp/literals.zag" --to explicit --output "$tmp/explicit.zag" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/expand.out" 2>"$tmp/expand.err"
grep -q 'script_map_new_checked' "$tmp/explicit.zag"
grep -q 'script_map_insert_checked' "$tmp/explicit.zag"
! grep -q '__zag_script_map_literal' "$tmp/explicit.zag"

"$compiler" "$tmp/explicit.zag" -o "$tmp/explicit" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/explicit.compile.out" 2>"$tmp/explicit.compile.err"
set +e
"$tmp/explicit" >"$tmp/explicit.out" 2>"$tmp/explicit.err"
explicit_status=$?
set -e

test "$compact_status" -eq "$explicit_status"
diff -u "$tmp/compact.out" "$tmp/explicit.out"
diff -u "$tmp/compact.err" "$tmp/explicit.err"

echo "script map explicit expansion: PASS"
