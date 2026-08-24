#!/usr/bin/env bash
# Native runtime regression: repeated `_zag_exec_cmd` must remain under a
# small address-space cap and return allocator telemetry to its exact baseline.
# The program's only repeated allocation is the command path bridge, so an
# omitted parent-side free fails deterministically even when a size-class arena
# can reserve enough virtual address space for the short test.
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-"$(pwd)/znc"}
tmp=$(mktemp -d /tmp/zag-exec-runtime.XXXXXX)
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
"$compiler" tests/exec_runtime_lifetime.zag -o "$tmp/exec-runtime" --no-zagd --no-analyze >/dev/null
(ulimit -v 65536; "$tmp/exec-runtime")
echo "exec runtime lifetime: pass commands=512 captures=32 limit_kib=65536"
