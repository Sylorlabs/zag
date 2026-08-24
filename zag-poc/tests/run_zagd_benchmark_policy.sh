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
if grep -Eq 'zagd_benchmark_select_99|zagd_deep_select|zagd_ingest_measurement' selfhost/zagd_daemon.zag; then
    echo "zagd benchmark policy: checked selector must remain unwired until the production record carries complete evidence" >&2
    exit 1
fi
grep -Eq '^optimization[[:space:]]+confidence-gated benchmark selection with no regressions[[:space:]]+partial[[:space:]]' tests/zagscript_1_0_capabilities.tsv
echo "zagd benchmark policy: pass (99% checked selector remains partial and advisory)"
