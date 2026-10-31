#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-"$PWD/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-semantic-registry-graph.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$compiler" check selfhost/semantic_manifest.zag \
    --no-zagd --no-foreground-cache >"$tmp/check.log" 2>&1
grep -q 'znc: OK — all capability claims proven' "$tmp/check.log"
"$compiler" selfhost/semantic_manifest_registry_graph_test.zag \
    -o "$tmp/test" --no-zagd --no-analyze --no-foreground-cache \
    >"$tmp/build.log" 2>&1
test -x "$tmp/test"
"$tmp/test" >"$tmp/out"
grep -qx 'semantic manifest registry graph: 4/4' "$tmp/out"
echo 'semantic manifest registry graph: pass=4 fail=0 (identity and fail-closed records)'
