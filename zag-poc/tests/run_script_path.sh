#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/${compiler#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-path.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$compiler" tests/script_frontend/path_helpers.zag -o "$tmp/path" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/path"
"$tmp/path"

cat >"$tmp/budget.zag" <<'ZAG'
script;
let fill:*i8 = script_alloc(1048576);
let joined: []u8 = path_join("tmp", "report.json");
println(joined);
return 0;
ZAG
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp/.zagd.conf"
"$compiler" "$tmp/budget.zag" -o "$tmp/budget" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/budget"
set +e
"$tmp/budget" >"$tmp/budget.out" 2>"$tmp/budget.err"
status=$?
set -e
test "$status" -eq 1
grep -q 'Zag Script memory limit exceeded by path_join' "$tmp/budget.err"

echo 'script path: pass=2 fail=0'
