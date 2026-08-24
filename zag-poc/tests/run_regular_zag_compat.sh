#!/usr/bin/env bash
# Script lowering is root-profile-only. This prevents ordinary Zag from quietly
# receiving a generated entry point or Script defaults.
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
case "$compiler" in
    /*) ;;
    *) compiler="$(pwd)/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-regular-compat.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

printf '%s\n' 'fn main() i32 { return 29; }' >"$tmp/regular-main.zag"
"$compiler" "$tmp/regular-main.zag" -o "$tmp/regular-main" --no-zagd --no-analyze >/dev/null
set +e
"$tmp/regular-main"
status=$?
set -e
test "$status" -eq 29

# Inspection and strict checking must report the regular profile, its user
# entry point, and no Script allocator.
"$compiler" explain "$tmp/regular-main.zag" --format json --no-zagd >"$tmp/explain.json"
grep -q '"profile":{"value":"strict","basis":"proven"}' "$tmp/explain.json"
grep -q '"entry_point":{"value":"user-defined","basis":"derived"}' "$tmp/explain.json"
grep -q '"allocator":{"value":"no script default","basis":"proven"}' "$tmp/explain.json"
"$compiler" check "$tmp/regular-main.zag" --strict --no-zagd >/dev/null

# A library-shaped regular source must retain the existing literal-main rule.
printf '%s\n' 'fn library() i32 { return 0; }' >"$tmp/no-main.zag"
if "$compiler" "$tmp/no-main.zag" -o "$tmp/no-main" --no-zagd --no-analyze >"$tmp/no-main.log" 2>&1; then
    echo 'regular Zag without main unexpectedly received an entry point' >&2
    exit 1
fi
grep -q 'native: no main function found' "$tmp/no-main.log"
test ! -e "$tmp/no-main"

echo 'regular Zag compatibility: PASS'
