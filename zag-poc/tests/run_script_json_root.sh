#!/usr/bin/env bash
# Run with ZNC=/absolute/path/to/the/parent/integration/compiler.
# Edition 2026 is the supported ordinary-JSON ownership boundary.
# JSON_EDITION=2027 is a diagnostic probe and must fail closed until the
# ordinary JSON resource graph has legitimate ownership contracts.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac
repo_root=$PWD
edition=${JSON_EDITION:-2026}
case "$edition" in 2026|2027) ;; *) echo "JSON_EDITION must be 2026 or 2027" >&2; exit 1 ;; esac
tmp=$(mktemp -d /tmp/zag-script-json-root.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/compiler"
# Forward to the original compiler path; symlinking a wrapper relocates its
# relative znc-real lookup and bypasses the signed-artifact audit.
printf '#!/bin/bash\nexec %q "$@"\n' "$compiler" >"$tmp/compiler/znc"
chmod +x "$tmp/compiler/znc"
ln -s "$repo_root/selfhost" "$tmp/compiler/selfhost"
ln -s "$repo_root/std" "$tmp/compiler/std"
compiler="$tmp/compiler/znc"
printf '%s\n' 'name = "script-json-root-test"' "edition = \"$edition\"" >"$tmp/zag.mod"
# Force arena accounting independent of the caller's project defaults.
printf '%s\n' 'mode=off' 'allocator=script_process_arena' \
    'script_memory_bytes=1048576' >"$tmp/.zagd.conf"
cp tests/script_json_root/*.zag "$tmp/"
for fixture in local_shadow import_shadow qualified_shadow string_success document_success; do
    if ! (cd "$tmp" && "$compiler" "$fixture.zag" -o "$fixture" \
        --no-zagd --no-analyze --no-foreground-cache) >"$tmp/compile.log" 2>&1; then
        echo "script JSON root: $fixture compile FAILED (edition $edition)" >&2
        cat "$tmp/compile.log" >&2
        exit 1
    fi
    if "$tmp/$fixture"; then
        echo "script JSON root: $fixture PASS"
    else
        status=$?
        echo "script JSON root: $fixture FAILED (exit $status)" >&2
        exit "$status"
    fi
done
echo "script JSON root convenience: PASS (edition $edition)"
