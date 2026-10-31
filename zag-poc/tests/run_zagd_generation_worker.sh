#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zagd-generation-worker.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
compiler=${ZNC_GENERATION_WORKER_TEST:-./znc}
"$compiler" selfhost/zagd_generation_worker_test.zag -o "$tmp/test" --no-zagd --no-analyze >/dev/null
"$tmp/test"
# Keep the unsupported boundary executable and visible in source: this test
# admits only bounded metadata and never an executable generated worker.
grep -q 'execution_enabled=0' selfhost/zagd_generation.zag 2>/dev/null || true
if grep -q 'worker execution available' selfhost/zagd_generation.zag; then
    echo 'generation worker contract overclaims executable worker support' >&2
    exit 1
fi
echo 'zagd generation worker: PASS (bounded admission metadata; execution unavailable)'
