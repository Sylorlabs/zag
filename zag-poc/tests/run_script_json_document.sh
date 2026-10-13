#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-json-document.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' 'name = "script-json-document-test"' >"$tmp/zag.mod"
mkdir -p "$tmp/tests" "$tmp/selfhost/std" "$tmp/std"
cp tests/script_json_document.zag "$tmp/tests/"
cp selfhost/std/script_json_document.zag "$tmp/selfhost/std/"
cp std/json.zag std/list.zag std/rt.zag "$tmp/std/"
if [[ ${JSON_EDITION:-2026} == 2027 ]]; then
    printf '%s\n' 'edition = "2027"' >>"$tmp/zag.mod"
fi
"$compiler" "$tmp/tests/script_json_document.zag" -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/compile.log" 2>&1 || {
    cat "$tmp/compile.log" >&2
    exit 1
}
"$tmp/test"
echo "script JSON document facade: PASS"
