#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-script-list.XXXXXX)
trap 'find "$tmp" -depth -delete' EXIT HUP INT TERM

"$compiler" tests/script_frontend/list.zag -o "$tmp/list" --no-zagd --no-analyze >/dev/null
"$tmp/list"
if "$compiler" tests/script_frontend/list_mixed_bad.zag -o "$tmp/bad" --no-zagd --no-analyze >"$tmp/bad.log" 2>&1; then
    echo "mixed Script list unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/bad"
echo "script typed list: PASS"
