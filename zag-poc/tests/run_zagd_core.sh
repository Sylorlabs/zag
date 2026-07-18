#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagd-core.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

./znc tests/zagd_core.zag -o "$tmp/zagd_core"
"$tmp/zagd_core"
echo "zagd core pass"
