#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC="${ZNC:-./znc}"
work="$(mktemp -d /tmp/zag_v2_list_owner.XXXXXX)"
trap 'rm -rf "$work"' EXIT

"$ZNC" tests/stdlib/list_v2_named_owner.zag \
  --no-zagd --analyze-strict --no-foreground-cache \
  -o "$work/list-v2-named-owner"
"$work/list-v2-named-owner"

echo "v2 list named-owner release: PASS"
