#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-package-registry-graph-lock.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$ZNC_BIN" check selfhost/package_registry_transitive.zag --analyze-strict \
    --no-zagd --no-foreground-cache >"$tmp/check.log" 2>&1
grep -q 'znc: OK — all capability claims proven' "$tmp/check.log"

"$ZNC_BIN" selfhost/package_registry_graph_lock_test.zag -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1
test -x "$tmp/test"
"$tmp/test" >"$tmp/out"
grep -qx 'package registry graph lock: 5/5' "$tmp/out"

echo 'package registry graph lock: pass=5 fail=0 (offline lock verification)'
