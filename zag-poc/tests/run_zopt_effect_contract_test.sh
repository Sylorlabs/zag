#!/usr/bin/env bash
# Experimental optimizer correctness regression, not a production release gate.
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zopt-effect-contract.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" selfhost/native/zopt_effect_contract_test.zag -o "$tmp/test" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/test"
