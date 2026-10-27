#!/usr/bin/env bash
# Verify a flat installed std directory without repository-relative imports.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac
tmp=$(mktemp -d /tmp/zag-script-json-installed.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/prefix/bin" "$tmp/prefix/lib/zag/std" "$tmp/project"
# The release authority passes an audit wrapper with a sibling `znc-real`.
# Install the exact underlying native compiler binary so its std: lookups use
# the staged prefix. Audit each resulting executable under the same signature
# requirement as the authority wrapper, preserving its central evidence log.
native_compiler=$compiler
audit_dir=
if [ -e "$(dirname "$compiler")/znc-real" ] && \
   [ "$(head -c 2 "$compiler")" = '#!' ]; then
    native_compiler="$(dirname "$compiler")/znc-real"
    audit_dir=$(dirname "$compiler")
fi
cp -L "$native_compiler" "$tmp/prefix/bin/znc"
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
    if [ -n "$audit_dir" ]; then
        artifact="$tmp/project/$fixture"
        kind=$(/usr/bin/file -b "$artifact" 2>/dev/null)
        if [ "$kind" != 'Mach-O 64-bit executable arm64' ] ||
           ! /usr/bin/codesign --verify --deep --strict "$artifact" >/dev/null 2>&1; then
            printf '%s\n' "$artifact" >>"$audit_dir/invalid-artifacts.log"
            echo "installed compiler produced an unsigned or wrong-architecture fixture: $artifact" >&2
            exit 97
        fi
        printf '%s\n' "$artifact" >>"$audit_dir/artifacts.log"
    fi
    "$tmp/project/$fixture"
done
echo "script JSON flat installed modules: PASS"
