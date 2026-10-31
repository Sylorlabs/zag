#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-zir-error-flow.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" selfhost/zir_error_flow_test.zag -o "$tmp/zir_error_flow_test" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/zir_error_flow_test"
printf 'ZIR error flow: pass\n'
