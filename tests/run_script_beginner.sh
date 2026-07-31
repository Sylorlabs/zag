#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
tmp=$(mktemp -d /tmp/zag-script-beginner.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

"$compiler" "$root/tests/script_frontend/beginner_collections.zag" -o "$tmp/beginner" --no-zagd --no-analyze >/dev/null
output=$("$tmp/beginner")
if [ "$output" != "4" ]; then
    echo "script beginner: expected list length 4, got: $output" >&2
    exit 1
fi

cat >"$tmp/arity.zag" <<'ZAG'
script;
let numbers = list(1, 2);
append(numbers);
ZAG
if "$compiler" "$tmp/arity.zag" -o "$tmp/bad" --no-zagd --no-analyze >"$tmp/arity.log" 2>&1; then
    echo "script beginner: append arity error unexpectedly compiled" >&2
    exit 1
fi
grep -q 'Zag Script append expects a list and one value' "$tmp/arity.log"

echo "script beginner: PASS"
