#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
tmp=$(mktemp -d /tmp/zagd-benchmark.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$ZNC_BIN" tests/zagd_benchmark_policy.zag -o "$tmp/test" --no-zagd --no-analyze >/dev/null
"$tmp/test"
if ! grep -q 'zagd_benchmark_select_99' selfhost/zagd_daemon.zag; then
    echo "zagd benchmark policy: daemon must invoke the checked selector" >&2
    exit 1
fi
if grep -Eq 'zagd_deep_select|zagd_ingest_measurement' selfhost/zagd_daemon.zag; then
    echo "zagd benchmark policy: obsolete selector bridge remains present" >&2
    exit 1
fi
grep -q 'legacy-three-pair-record-insufficient-for-99-percent-selection' selfhost/zagd_daemon.zag
grep -Eq '^optimization[[:space:]]+confidence-gated benchmark selection with no regressions[[:space:]]+partial[[:space:]]' tests/zagscript_1_0_capabilities.tsv
echo "zagd benchmark policy: pass (selector invoked; incomplete evidence is verified_no_win and remains advisory)"
