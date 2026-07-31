#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zagd-benchmark.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
./znc tests/zagd/zagd_benchmark_policy.zag -o "$tmp/test" --no-zagd --no-analyze >/dev/null
"$tmp/test"
echo "zagd benchmark execution policy: pass (explicit deep and equivalence gated)"
