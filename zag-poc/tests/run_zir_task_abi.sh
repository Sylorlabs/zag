#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-zir-task-abi.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" selfhost/zir_task_abi_test.zag -o "$tmp/zir_task_abi_test" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/zir_task_abi_test"
printf 'ZIR TaskI64 ABI: pass\n'
