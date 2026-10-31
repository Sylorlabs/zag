#!/usr/bin/env bash
# Frozen v1 static-type authority: semantic execution plus declared-type
# diagnostics.  Keep this as one matrix evidence authority so a supported row
# cannot silently cite only a narrow sub-suite.
set -eu
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
tmp=$(mktemp -d /tmp/zag-static-types.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

if ! ZNC="$ZNC" bash tests/run_semantics.sh >"$tmp/semantics.log" 2>&1; then
    sed -n '1,24p' "$tmp/semantics.log"
    exit 1
fi
grep -q '^==== semantics pass=24 fail=0 known_gaps=0 ====$' "$tmp/semantics.log"

if ! ZNC="$ZNC" bash tests/run_typed_authority.sh >"$tmp/typed.log" 2>&1; then
    sed -n '1,24p' "$tmp/typed.log"
    exit 1
fi
grep -q '^════ typed-authority pass=12 fail=0 ════$' "$tmp/typed.log"

echo "static-type-authority pass=2 fail=0 (semantics=24/24 typed=12/12)"
