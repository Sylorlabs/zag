#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
ZNC="${ZNC:-./znc}"
"$ZNC" tests/gpu_platform.zag -o /tmp/zag_gpu_platform_test
/tmp/zag_gpu_platform_test
