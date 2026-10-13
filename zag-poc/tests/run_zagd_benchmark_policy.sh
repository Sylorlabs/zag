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

# Production authority must use the same checked selector on every daemon host,
# persist the complete v3 evidence vectors, and stay advisory to foreground
# compilation. Source guards catch accidental policy drift before the slower
# product integration suite runs.
for daemon in selfhost/zagd_daemon.zag selfhost/zagd_macos_daemon.zag; do
    grep -q 'zagd_benchmark_select_99' "$daemon"
    grep -q 'zagd-deep-measurement-v3' "$daemon"
    grep -q 'foreground_consumption=false' "$daemon"
    grep -q 'selector=paired-sign-familywise-99' "$daemon"
done

# Run the production integration against a daemon rebuilt from the same source
# and compiler authority as this gate. An ambient ZAGD may be an older checkout
# artifact and must not decide whether the current v3 policy passes.
env -u ZAGD ZNC="$ZNC_BIN" bash tests/run_zagd_deep_integration.sh
grep -Eq '^optimization[[:space:]]+confidence-gated benchmark selection with no regressions[[:space:]]+supported[[:space:]]+tests/run_zagd_benchmark_policy.sh$' \
    tests/zagscript_1_0_capabilities.tsv
echo "zagd benchmark policy: pass (99% checked selector + production v3 integration)"
