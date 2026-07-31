#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
ZNC="${ZNC:-./znc}"
"$ZNC" tests/gpu/gpu_isolation.zag -o /tmp/zag_gpu_isolation_test
/tmp/zag_gpu_isolation_test
