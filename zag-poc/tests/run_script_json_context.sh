#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-json-context.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' 'name = "script-json-context-test"' >"$tmp/zag.mod"
mkdir -p "$tmp/tests" "$tmp/selfhost/std" "$tmp/std"
cp tests/script_json_context.zag "$tmp/tests/"
cp selfhost/std/script_json.zag "$tmp/selfhost/std/"
cp std/json.zag std/list.zag std/rt.zag "$tmp/std/"
"$compiler" "$tmp/tests/script_json_context.zag" -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/compile.log" 2>&1 || {
    cat "$tmp/compile.log" >&2
    exit 1
}
"$tmp/test"
echo "script context JSON: PASS"
