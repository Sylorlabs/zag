#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zagd-benchmark-evidence.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" selfhost/zagd_benchmark_evidence_test.zag -o "$tmp/test" --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/test"
test "$("$tmp/test")" = 'zagd benchmark evidence: 10/10'
grep -q 'zagd_benchmark_evidence_decode' selfhost/zagd_daemon.zag
grep -q 'zagd_policy_selector_current' selfhost/zagd_daemon.zag
grep -q 'policy_record_valid' selfhost/zagd_daemon.zag
echo 'zagd benchmark evidence: pass (v2 samples revalidated by selector; checksummed fail-closed publication)'
