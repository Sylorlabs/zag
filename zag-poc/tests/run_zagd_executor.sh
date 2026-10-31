#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zagd-executor.XXXXXX)
trap 'find "$tmp" -depth -delete' EXIT
compiler=${ZNC:-./znc}
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/${compiler#./}" ;;
esac
"$compiler" tests/zagd_executor.zag -o "$tmp/test" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_witness.zag -o "$tmp/witness" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_slow.zag -o "$tmp/slow" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_noisy.zag -o "$tmp/noisy" --no-zagd --no-analyze >/dev/null
"$tmp/test" "$tmp/witness" "$tmp/slow" "$tmp/noisy"
echo 'zagd direct executor: pass'
