#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagd-core.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

compiler=${ZNC:-./znc}
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/${compiler#./}" ;;
esac

"$compiler" tests/zagd_core.zag -o "$tmp/zagd_core"
"$tmp/zagd_core"
"$compiler" selfhost/zagd_store_test.zag -o "$tmp/zagd_store_test" --no-zagd --no-analyze
"$tmp/zagd_store_test"
echo "zagd core pass"
