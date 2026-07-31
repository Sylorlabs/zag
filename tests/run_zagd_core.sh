#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagd-core.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

./znc tests/zagd/zagd_core.zag -o "$tmp/zagd_core"
"$tmp/zagd_core"
./znc selfhost/zagd_store_test.zag -o "$tmp/zagd_store_test" --no-zagd --no-analyze
"$tmp/zagd_store_test"
echo "zagd core pass"
