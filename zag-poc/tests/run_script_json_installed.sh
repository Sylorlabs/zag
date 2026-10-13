#!/usr/bin/env bash
# Verify a flat installed std directory without repository-relative imports.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-json-installed.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/prefix/bin" "$tmp/prefix/lib/zag/std" "$tmp/project"
cp "$compiler" "$tmp/prefix/bin/znc"
cp std/json.zag std/list.zag std/rt.zag selfhost/std/script_json.zag \
    selfhost/std/script_json_document.zag "$tmp/prefix/lib/zag/std/"
printf '%s\n' 'name = "script-json-installed-test"' >"$tmp/project/zag.mod"
for fixture in script_json_context script_json_document; do
    sed -e 's|../selfhost/std/script_json.zag|std:script_json|' \
        -e 's|../selfhost/std/script_json_document.zag|std:script_json_document|' \
        "tests/$fixture.zag" >"$tmp/project/$fixture.zag"
    (cd "$tmp/project" && "$tmp/prefix/bin/znc" "$fixture.zag" -o "$fixture" \
        --no-zagd --no-analyze --no-foreground-cache) >"$tmp/compile.log" 2>&1 || {
        cat "$tmp/compile.log" >&2
        exit 1
    }
    "$tmp/project/$fixture"
done
echo "script JSON flat installed modules: PASS"
