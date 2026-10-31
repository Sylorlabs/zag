#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-resolve-authority.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$ZNC_BIN" check selfhost/package_registry_graph_authority.zag \
    --analyze-strict --no-zagd --no-foreground-cache >"$tmp/check.log" 2>&1
grep -q 'znc: OK — all capability claims proven' "$tmp/check.log"

"$ZNC_BIN" selfhost/package_resolve_graph_authority_test.zag -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1
test -x "$tmp/test"
"$tmp/test" >"$tmp/out"
grep -qx 'package resolve graph authority: 8/8' "$tmp/out"

echo 'package resolve graph authority: pass=8 fail=0 (explicit foreground admission)'
