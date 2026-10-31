#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zagd-incremental.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
compiler=${ZNC:-./znc}
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/${compiler#./}" ;;
esac
"$compiler" selfhost/zagd_incremental_test.zag -o "$tmp/test" --no-zagd --no-analyze >/dev/null
"$tmp/test"
