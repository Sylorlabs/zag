#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-format.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' 'name = "script-format-test"' 'edition = "2027"' >"$tmp/zag.mod"
mkdir -p "$tmp/tests" "$tmp/selfhost/std"
cp tests/script_format.zag "$tmp/tests/"
cp selfhost/std/script_format.zag selfhost/std/script_string.zag "$tmp/selfhost/std/"
"$compiler" "$tmp/tests/script_format.zag" -o "$tmp/script_format" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/compile.log" 2>&1 || {
    cat "$tmp/compile.log" >&2
    exit 1
}
"$tmp/script_format"
echo "script typed formatting: PASS"
