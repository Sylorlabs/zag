#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./znc tests/gpu/gpu_std.zag -o /tmp/zag_gpu_std_test
/tmp/zag_gpu_std_test
